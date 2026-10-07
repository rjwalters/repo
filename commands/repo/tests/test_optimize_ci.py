#!/usr/bin/env python3
"""Behavioral tests for scripts/repo/repo-optimize-ci.py (/repo:optimize-ci, #505).

Fixture workflows are written to temp dirs; every GitHub read goes through an
in-memory double, so this suite needs no network and cannot write anywhere.
`pnpm test` delegates here via hooks/repo/tests/run.sh.

Pinned contracts (the acceptance criteria of #505):
  - a workflow containing a REQUIRED check never gets a workflow-level `paths:`
    recommendation — only the job-level filter + always-running gate pattern;
  - every cache anti-pattern is detected, per toolchain;
  - missing concurrency is detected, and no recommendation ever cancels
    default-branch pushes;
  - under-filtered PR `paths:` (lockfile / workflow file / local action) is detected;
  - unreadable protection / Actions history degrades to "unknown" / "not
    measured" without failing, and findings rank by estimated minutes saved.
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "scripts/repo/repo-optimize-ci.py"
SPEC = importlib.util.spec_from_file_location("optimize_ci", HELPER)
oc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(oc)


def make_repo(workflows, root_files=("package.json", "package-lock.json")):
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    (root / ".github/workflows").mkdir(parents=True)
    for name, body in workflows.items():
        (root / ".github/workflows" / name).write_text(textwrap.dedent(body))
    for name in root_files:
        (root / name).write_text("{}\n")
    return tmp, root


def scan(workflows, required=(), root_files=("package.json", "package-lock.json"),
         required_unknown=False):
    tmp, root = make_repo(workflows, root_files)
    with tmp:
        args = ["scan", "--root", str(root)]
        for ctx in required:
            args += ["--required", ctx]
        if required_unknown:
            args.append("--required-unknown")
        ns = argparse_ns(args)
        return oc.run_scan(ns)


def argparse_ns(argv):
    captured = {}

    def fake_scan(args):
        captured["args"] = args
        return {}
    with patch.object(oc, "run_scan", fake_scan), patch.object(oc, "render_text", lambda r: ""), \
            patch("sys.stdout"):
        oc.main(argv)
    return captured["args"]


def ids(report, workflow=None):
    return [f["id"] for f in report["findings"]
            if workflow is None or f["workflow"].endswith(workflow)]


def only(report, fid):
    hits = [f for f in report["findings"] if f["id"] == fid]
    assert len(hits) == 1, f"expected exactly one {fid}, got {ids(report)}"
    return hits[0]


NODE_TEST = """\
    name: CI
    on:
      pull_request:{paths}
      push:
        branches: [main]
    concurrency:
      group: ci-${{{{ github.ref }}}}
      cancel-in-progress: ${{{{ github.event_name == 'pull_request' }}}}
    jobs:
      test:
        name: unit tests
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: actions/setup-node@v4
            with:
              node-version: 20
              cache: npm
          - run: npm ci
          - run: npm test
"""


def node_workflow(paths=None):
    if paths is None:
        return NODE_TEST.format(paths="")
    block = "".join(f"\n        - \"{p}\"" for p in paths)
    return NODE_TEST.format(paths="\n        paths:" + block)


class YamlReaderTests(unittest.TestCase):
    def test_on_key_stays_a_string_not_boolean_true(self):
        doc = oc.parse_yaml("on:\n  push:\n    branches: [main]\n")
        self.assertIn("on", doc)
        self.assertEqual(doc["on"]["push"]["branches"], ["main"])

    def test_block_scalars_follow_chomping_and_folding(self):
        doc = oc.parse_yaml(textwrap.dedent("""\
            a: |
              one
              two
            b: >-
              folded
              line

              para
            c: "quoted # not a comment" # a comment
            d: [x, 'y, z']
            e:
            - 1
            - true
        """))
        self.assertEqual(doc["a"], "one\ntwo\n")
        self.assertEqual(doc["b"], "folded line\npara")
        self.assertEqual(doc["c"], "quoted # not a comment")
        self.assertEqual(doc["d"], ["x", "y, z"])
        self.assertEqual(doc["e"], [1, True])

    def test_sequence_of_mappings(self):
        doc = oc.parse_yaml("steps:\n  - uses: a@v1\n    with:\n      k: v\n  - run: echo hi\n")
        self.assertEqual(doc["steps"], [{"uses": "a@v1", "with": {"k": "v"}}, {"run": "echo hi"}])

    def test_invalid_workflow_is_reported_not_raised(self):
        report = scan({"bad.yml": "on: push\njobs:\n  x:\n    steps: |\n  junk\nnot a key\n"})
        self.assertIn("unparseable-workflow", ids(report))


class GlobTests(unittest.TestCase):
    def test_github_path_filter_semantics(self):
        self.assertTrue(oc.filter_matches(["src/**"], "src/a/b.js"))
        self.assertFalse(oc.filter_matches(["src/*"], "src/a/b.js"))
        self.assertTrue(oc.filter_matches(["**/*.lock"], "Cargo.lock"))
        self.assertTrue(oc.filter_matches(["**"], "package-lock.json"))
        # Order matters: the last matching pattern wins.
        self.assertFalse(oc.filter_matches(["src/**", "!src/docs/**"], "src/docs/x.md"))
        self.assertTrue(oc.filter_matches(["!src/docs/**", "src/**"], "src/docs/x.md"))

    def test_doc_only_classification_does_not_treat_all_markdown_as_docs(self):
        self.assertTrue(oc.is_doc_only("README.md"))
        self.assertTrue(oc.is_doc_only("docs/guide/setup.md"))
        # In a prompt/skill repo markdown is the product.
        self.assertFalse(oc.is_doc_only("commands/repo/deps.md"))


class RequiredCheckSafetyTests(unittest.TestCase):
    def assert_no_workflow_level_paths_recommended(self, report):
        for f in report["findings"]:
            if f["id"] in ("unfiltered-pr-workflow", "required-check-workflow-paths"):
                self.assertNotIn("a workflow-level filter is safe", f["recommendation"])
                self.assertIn("dorny/paths-filter", f["recommendation"])
                self.assertIn("aggregator", f["recommendation"])

    def test_required_check_with_workflow_level_paths_recommends_job_level_filter(self):
        report = scan({"ci.yml": node_workflow(["src/**", "package-lock.json", "package.json",
                                                ".github/workflows/ci.yml"])},
                      required=["unit tests"])
        f = only(report, "required-check-workflow-paths")
        self.assertEqual(f["severity"], "critical")
        self.assertIn("blocked forever", f["message"])
        self.assertIn("Remove the workflow-level", f["recommendation"])
        self.assert_no_workflow_level_paths_recommended(report)
        self.assertEqual(report["findings"][0]["id"], "required-check-workflow-paths")

    def test_required_check_matched_by_job_id_and_matrix_suffix(self):
        wf = node_workflow(["src/**"]).replace("name: unit tests", "name: test")
        self.assertIn("required-check-workflow-paths", ids(scan({"ci.yml": wf}, required=["test (ubuntu, 20)"])))
        self.assertIn("required-check-workflow-paths", ids(scan({"ci.yml": wf}, required=["test"])))

    def test_unfiltered_workflow_with_required_check_never_gets_workflow_paths(self):
        report = scan({"ci.yml": node_workflow()}, required=["unit tests"])
        f = only(report, "unfiltered-pr-workflow")
        self.assertIn("do NOT add workflow-level `paths:`", f["recommendation"])
        self.assert_no_workflow_level_paths_recommended(report)

    def test_unknown_required_checks_are_treated_as_possibly_required(self):
        report = scan({"ci.yml": node_workflow()}, required_unknown=True)
        f = only(report, "unfiltered-pr-workflow")
        self.assertIn("could not be (fully) read", f["recommendation"])
        self.assert_no_workflow_level_paths_recommended(report)

    def test_no_required_checks_allows_workflow_level_ignore(self):
        f = only(scan({"ci.yml": node_workflow()}), "unfiltered-pr-workflow")
        self.assertIn("a workflow-level filter is safe", f["recommendation"])
        self.assertIn("Never ignore lockfiles", f["recommendation"])

    def test_existing_job_level_filter_is_not_flagged(self):
        wf = node_workflow() + textwrap.indent(textwrap.dedent("""\
              changes:
                runs-on: ubuntu-latest
                steps:
                  - uses: dorny/paths-filter@v3
        """), " " * 6)
        self.assertNotIn("unfiltered-pr-workflow", ids(scan({"ci.yml": wf}, required=["unit tests"])))


class UnderFilterTests(unittest.TestCase):
    def test_paths_omitting_lockfile_and_workflow_file_is_flagged(self):
        report = scan({"ci.yml": node_workflow(["src/**", "package.json"])})
        f = only(report, "under-filtered-paths")
        self.assertIn("`package-lock.json`", f["message"])
        self.assertIn("`.github/workflows/ci.yml`", f["message"])
        self.assertNotIn("`package.json`", f["message"])

    def test_complete_paths_is_clean(self):
        report = scan({"ci.yml": node_workflow(["src/**", "package*.json", ".github/workflows/**"])})
        self.assertNotIn("under-filtered-paths", ids(report))

    def test_lockfile_absent_from_repo_is_not_demanded(self):
        report = scan({"ci.yml": node_workflow(["src/**", "package.json", ".github/workflows/ci.yml"])},
                      root_files=("package.json",))
        self.assertNotIn("under-filtered-paths", ids(report))

    def test_paths_ignore_excluding_a_lockfile_is_flagged(self):
        wf = node_workflow().replace("pull_request:", "pull_request:\n        paths-ignore: ['**/*.json']")
        f = only(scan({"ci.yml": wf}), "under-filtered-paths")
        self.assertIn("`paths-ignore:` excludes", f["message"])
        self.assertIn("package-lock.json", f["message"])

    def test_local_composite_action_is_an_input(self):
        wf = node_workflow(["src/**", "package*.json", ".github/workflows/ci.yml"]).replace(
            "- run: npm test", "- uses: ./.github/actions/setup")
        f = only(scan({"ci.yml": wf}), "under-filtered-paths")
        self.assertIn(".github/actions/setup/action.yml", f["message"])

    def test_push_only_paths_are_deliberate_scoping_not_flagged(self):
        wf = textwrap.dedent("""\
            on:
              push:
                branches: [main]
                paths: ['src/**']
            jobs:
              release:
                runs-on: ubuntu-latest
                steps:
                  - run: npm publish
        """)
        self.assertNotIn("under-filtered-paths", ids(scan({"release.yml": wf})))


CACHE_WF = """\
    on:
      pull_request:
    concurrency:
      group: ${{{{ github.ref }}}}
      cancel-in-progress: ${{{{ github.event_name == 'pull_request' }}}}
    jobs:
      build:
        runs-on: ubuntu-latest{matrix}
        steps:
          - uses: actions/cache@v4
            with:
              path: ~/.npm
              key: {key}{restore}
          - run: npm ci
"""


def cache_wf(key, restore=None, matrix=False):
    return CACHE_WF.format(
        key=key,
        restore=f"\n              restore-keys: {restore}" if restore else "",
        matrix="\n        strategy:\n          matrix:\n            node: [18, 20]" if matrix else "")


class CacheTests(unittest.TestCase):
    def test_sha_keyed_cache_never_hits(self):
        f = only(scan({"c.yml": cache_wf("npm-${{ github.sha }}")}), "cache-key-never-hits")
        self.assertEqual(f["severity"], "high")
        self.assertIn("hashFiles", f["recommendation"])
        self.assertEqual(f["job"], "build")

    def test_run_id_keyed_cache_with_restore_keys_is_lower_severity(self):
        report = scan({"c.yml": cache_wf("npm-${{ github.run_id }}", restore="npm-")})
        self.assertEqual(only(report, "cache-key-never-hits")["severity"], "low")

    def test_key_without_lockfile_hash_never_invalidates(self):
        f = only(scan({"c.yml": cache_wf("${{ runner.os }}-npm")}), "cache-key-no-lockfile-hash")
        self.assertIn("never invalidates", f["message"])

    def test_good_key_is_clean_but_missing_restore_keys_is_noted(self):
        def cache_ids(report):
            return [f["id"] for f in report["findings"] if f["category"] == "cache"]
        report = scan({"c.yml": cache_wf("${{ runner.os }}-npm-${{ hashFiles('package-lock.json') }}")})
        self.assertEqual(cache_ids(report), ["cache-no-restore-keys"])
        report = scan({"c.yml": cache_wf("${{ runner.os }}-npm-${{ hashFiles('package-lock.json') }}",
                                         restore="${{ runner.os }}-npm-")})
        self.assertEqual(cache_ids(report), [])

    def test_matrix_without_matrix_key_collides(self):
        report = scan({"c.yml": cache_wf("${{ runner.os }}-npm-${{ hashFiles('package-lock.json') }}",
                                         restore="x", matrix=True)})
        self.assertIn("cache-matrix-key-collision", ids(report))
        report = scan({"c.yml": cache_wf("${{ matrix.node }}-${{ hashFiles('package-lock.json') }}",
                                         restore="x", matrix=True)})
        self.assertNotIn("cache-matrix-key-collision", ids(report))

    def job(self, steps):
        body = textwrap.indent(textwrap.dedent(steps), " " * 10)
        return ("on:\n  pull_request:\nconcurrency:\n  group: g\n"
                "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n"
                "jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n" + body)

    def test_per_toolchain_missing_cache(self):
        cases = {
            "no-cache-node": ("- uses: actions/setup-node@v4\n- run: pnpm install\n",
                              "- uses: actions/setup-node@v4\n  with:\n    cache: pnpm\n- run: pnpm install\n"),
            "no-cache-python": ("- uses: actions/setup-python@v5\n- run: pip install -r requirements.txt\n",
                                "- uses: actions/setup-python@v5\n  with:\n    cache: pip\n"
                                "- run: pip install -r requirements.txt\n"),
            "no-cache-rust": ("- run: cargo test --locked\n",
                              "- uses: Swatinem/rust-cache@v2\n- run: cargo test --locked\n"),
            "no-cache-go": ("- uses: actions/setup-go@v5\n  with:\n    cache: false\n- run: go test ./...\n",
                            "- uses: actions/setup-go@v5\n- run: go test ./...\n"),
            "no-cache-docker": ("- uses: docker/build-push-action@v6\n  with:\n    push: false\n",
                                "- uses: docker/build-push-action@v6\n  with:\n    cache-from: type=gha\n"
                                "    cache-to: type=gha,mode=max\n"),
        }
        for fid, (bad, good) in cases.items():
            with self.subTest(fid):
                self.assertIn(fid, ids(scan({"w.yml": self.job(bad)})))
                self.assertNotIn(fid, ids(scan({"w.yml": self.job(good)})))

    def test_uv_cache_disabled_and_plain_docker_build(self):
        self.assertIn("no-cache-python", ids(scan({"w.yml": self.job(
            "- uses: astral-sh/setup-uv@v6\n  with:\n    enable-cache: false\n")})))
        self.assertIn("no-cache-docker", ids(scan({"w.yml": self.job("- run: docker build .\n")})))

    def test_identical_findings_in_one_job_collapse(self):
        steps = "- uses: docker/build-push-action@v6\n" * 3
        report = scan({"w.yml": self.job(steps)})
        self.assertEqual(only(report, "no-cache-docker")["occurrences"], 3)


class WastedRunTests(unittest.TestCase):
    PR_ONLY = "on:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n"

    def test_missing_concurrency_recommends_pr_only_cancel(self):
        f = only(scan({"w.yml": self.PR_ONLY}), "missing-concurrency")
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", f["recommendation"])
        self.assertNotIn("cancel-in-progress: true", f["recommendation"])

    def test_concurrency_without_cancel(self):
        wf = self.PR_ONLY.replace("jobs:", "concurrency: ci-${{ github.ref }}\njobs:")
        self.assertIn("concurrency-no-cancel", ids(scan({"w.yml": wf})))

    def test_unconditional_cancel_on_default_branch_push_is_flagged(self):
        wf = ("on:\n  pull_request:\n  push:\n    branches: [main]\n"
              "concurrency:\n  group: g-${{ github.ref }}\n  cancel-in-progress: true\n"
              "jobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n")
        f = only(scan({"w.yml": wf}), "cancel-on-default-branch")
        self.assertIn("github.event_name == 'pull_request'", f["recommendation"])
        # Same workflow but pushes only to a release branch: main is never cancelled.
        self.assertNotIn("cancel-on-default-branch",
                         ids(scan({"w.yml": wf.replace("[main]", "[release]")})))
        # PR-only workflow cancelling unconditionally is fine.
        pr_only = self.PR_ONLY.replace("jobs:", "concurrency:\n  group: g\n  cancel-in-progress: true\njobs:")
        self.assertNotIn("cancel-on-default-branch", ids(scan({"w.yml": pr_only})))

    def test_no_recommendation_anywhere_cancels_default_branch_runs(self):
        fixtures = [self.PR_ONLY, node_workflow(), cache_wf("x-${{ github.sha }}"),
                    self.PR_ONLY.replace("jobs:", "concurrency: g\njobs:")]
        for wf in fixtures:
            for f in scan({"w.yml": wf})["findings"]:
                self.assertNotIn("cancel-in-progress: true", f["recommendation"])

    def test_push_everywhere_plus_pr_runs_twice(self):
        wf = self.PR_ONLY.replace("on:\n  pull_request:", "on: [push, pull_request]")
        self.assertIn("duplicate-push-pr", ids(scan({"w.yml": wf})))
        self.assertNotIn("duplicate-push-pr", ids(scan({"w.yml": node_workflow()})))

    def test_non_pr_workflows_are_not_asked_for_concurrency(self):
        wf = "on:\n  schedule:\n    - cron: '0 0 * * *'\njobs:\n  t:\n    runs-on: x\n    steps:\n      - run: make\n"
        self.assertEqual(ids(scan({"w.yml": wf})), [])


class FakeGitHub:
    """In-memory GET-only double. Routes map endpoint prefixes to data or an HTTP status."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def api(self, endpoint):
        self.calls.append(endpoint)
        for prefix in sorted(self.routes, key=len, reverse=True):
            if endpoint.startswith(prefix):
                value = self.routes[prefix]
                if isinstance(value, int):
                    raise oc.ApiError(endpoint, f"gh: Error (HTTP {value})")
                return value
        raise oc.ApiError(endpoint, "gh: Not Found (HTTP 404)")


def run(i, event, branch, created, updated, sha, conclusion="success", prs=()):
    return {"id": i, "path": ".github/workflows/ci.yml", "event": event, "head_branch": branch,
            "head_sha": sha, "status": "completed", "conclusion": conclusion,
            "created_at": created, "run_started_at": created, "updated_at": updated,
            "pull_requests": [{"number": n} for n in prs]}


class ReportTests(unittest.TestCase):
    def report(self, routes, workflows, **kw):
        tmp, root = make_repo(workflows)
        with tmp:
            ns = type("A", (), dict(repo="o/r", root=str(root), remote=False, default_branch=None,
                                    runs=50, days=30, no_history=False, json=True))()
            for k, v in kw.items():
                setattr(ns, k, v)
            gh = FakeGitHub(routes)
            return oc.run_report(ns, gh=gh), gh

    def test_required_checks_union_of_classic_and_rulesets(self):
        gh = FakeGitHub({
            "repos/o/r/branches/main/protection/required_status_checks":
                {"contexts": ["a"], "checks": [{"context": "b"}]},
            "repos/o/r/rules/branches/main": [
                {"type": "required_status_checks",
                 "parameters": {"required_status_checks": [{"context": "c"}]}},
                {"type": "deletion"}],
        })
        info = oc.required_checks(gh, "o/r", "main")
        self.assertEqual(info["state"], "known")
        self.assertEqual(info["contexts"], ["a", "b", "c"])

    def test_protected_branch_with_protection_404_is_unknown_not_none(self):
        # GitHub answers 404 on the protection endpoint to every non-admin token,
        # even when checks are required (cli/cli, microsoft/vscode, rust-lang/rust).
        info = oc.required_checks(FakeGitHub({
            "repos/o/r/branches/main": {"protected": True},
            "repos/o/r/branches/main/protection": 404,
            "repos/o/r/rules/branches/main": []}), "o/r", "main")
        self.assertEqual(info["state"], "unknown")
        self.assertTrue(info["sources"]["classic"].startswith("unknown (404"))
        # Branch endpoint unreadable too: a protection 404 still proves nothing.
        info = oc.required_checks(FakeGitHub({"repos/o/r/rules/branches/main": []}), "o/r", "main")
        self.assertEqual(info["state"], "unknown")
        # Only an explicitly unprotected branch makes the 404 mean "none".
        info = oc.required_checks(FakeGitHub({
            "repos/o/r/branches/main": {"protected": False},
            "repos/o/r/branches/main/protection": 404,
            "repos/o/r/rules/branches/main": []}), "o/r", "main")
        self.assertEqual((info["state"], info["contexts"]), ("known", []))
        info = oc.required_checks(FakeGitHub({
            "repos/o/r/branches/main": 403, "repos/o/r/rules/branches/main": []}), "o/r", "main")
        self.assertEqual(info["state"], "unknown")

    def test_required_checks_read_from_branch_endpoint_without_admin(self):
        gh = FakeGitHub({
            "repos/o/r/branches/main": {"protected": True, "protection": {
                "enabled": True, "required_status_checks": {
                    "enforcement_level": "non_admins",
                    "contexts": ["build (ubuntu-latest)"],
                    "checks": [{"context": "build (macos-latest)", "app_id": None}]}}},
            "repos/o/r/branches/main/protection": 404,
            "repos/o/r/rules/branches/main": []})
        info = oc.required_checks(gh, "o/r", "main")
        self.assertEqual(info["state"], "known")
        self.assertFalse(info["partial"])
        self.assertEqual(info["contexts"], ["build (macos-latest)", "build (ubuntu-latest)"])
        self.assertEqual(info["sources"]["classic"], "read")
        self.assertNotIn("repos/o/r/branches/main/protection/required_status_checks", gh.calls)
        # Protected, but classic protection requires no checks: none, not unknown.
        info = oc.required_checks(FakeGitHub({
            "repos/o/r/branches/main": {"protected": True, "protection": {
                "enabled": True, "required_status_checks": {
                    "enforcement_level": "off", "contexts": [], "checks": []}}},
            "repos/o/r/rules/branches/main": []}), "o/r", "main")
        self.assertEqual((info["state"], info["sources"]["classic"]), ("known", "none"))
        # End to end, a required matrix job keeps the job-level recommendation.
        wf = node_workflow().replace("name: unit tests", "name: build")
        report, _ = self.report({
            "repos/o/r/branches/main": {"protected": True, "protection": {
                "required_status_checks": {"contexts": ["build (ubuntu-latest)"]}}},
            "repos/o/r/rules": [], "repos/o/r/actions": 403}, {"ci.yml": wf})
        f = only(report, "unfiltered-pr-workflow")
        self.assertIn("contains required check(s) `test`", f["recommendation"])
        self.assertNotIn("a workflow-level filter is safe", f["recommendation"])
        self.assertNotIn("none configured", oc.render_text(report))

    def test_partial_read_gives_unmatched_workflows_the_job_level_recommendation(self):
        routes = {"repos/o/r/branches/main": {"protected": True, "protection": {
                      "required_status_checks": {"contexts": ["lint"]}}},
                  "repos/o/r/rules": 403, "repos/o/r/actions": 403}
        report, _ = self.report(routes, {"ci.yml": node_workflow()})
        rc = report["requiredChecks"]
        self.assertEqual((rc["state"], rc["partial"], rc["contexts"]), ("known", True, ["lint"]))
        f = only(report, "unfiltered-pr-workflow")
        self.assertIn("could not be (fully) read", f["recommendation"])
        self.assertIn("dorny/paths-filter", f["recommendation"])
        self.assertNotIn("a workflow-level filter is safe", f["recommendation"])
        # An existing workflow-level filter gets a verify warning on a partial read.
        report, _ = self.report(routes, {"ci.yml": node_workflow(
            ["src/**", "package-lock.json", "package.json", ".github/workflows/ci.yml"])})
        self.assertEqual(only(report, "unverified-required-check-paths")["severity"], "medium")

    def test_history_unavailable_degrades_to_not_measured(self):
        report, gh = self.report({"repos/o/r/actions": 403, "repos/o/r/rules": []},
                                 {"ci.yml": WastedRunTests.PR_ONLY})
        self.assertEqual(report["history"]["state"], "not measured")
        self.assertIn("403", report["history"]["reason"])
        self.assertTrue(report["findings"])
        self.assertTrue(all(f["estMinutesSaved"] is None for f in report["findings"]))
        text = oc.render_text(report)
        self.assertIn("not measured", text)

    def test_protection_unreadable_forces_job_level_recommendation(self):
        report, _ = self.report({"repos/o/r/branches": 403, "repos/o/r/rules": 403,
                                 "repos/o/r/actions": 403}, {"ci.yml": node_workflow()})
        self.assertEqual(report["requiredChecks"]["state"], "unknown")
        self.assertIn("dorny/paths-filter", only(report, "unfiltered-pr-workflow")["recommendation"])

    def test_findings_rank_by_estimated_minutes_with_critical_first(self):
        runs = [
            # PR 1 is docs-only; PR 2 touches code. Two pushes to branch a, the
            # first still running when the second starts (superseded).
            run(1, "pull_request", "a", "2026-09-01T00:00:00Z", "2026-09-01T00:10:00Z", "s1", prs=[1]),
            run(2, "pull_request", "a", "2026-09-01T00:05:00Z", "2026-09-01T00:15:00Z", "s2", prs=[1]),
            run(3, "pull_request", "b", "2026-09-02T00:00:00Z", "2026-09-02T00:10:00Z", "s3"),
            run(4, "push", "main", "2026-09-03T00:00:00Z", "2026-09-03T00:10:00Z", "s4"),
        ]
        job = {"jobs": [{"name": "t", "started_at": "2026-09-01T00:00:00Z",
                         "completed_at": "2026-09-01T00:10:00Z"}]}
        routes = {
            "repos/o/r/rules": [],
            "repos/o/r/actions/runs?": {"workflow_runs": runs},
            "repos/o/r/actions/runs/": job,
            # Run 3 has an empty pull_requests array (merged + branch deleted):
            # resolved via the recent-PRs listing by head branch.
            "repos/o/r/pulls?": [{"number": 2, "head": {"ref": "b"}}],
            "repos/o/r/pulls/1/files": [{"filename": "README.md"}, {"filename": "docs/x.md"}],
            "repos/o/r/pulls/2/files": [{"filename": "src/app.js"}],
        }
        wf = WastedRunTests.PR_ONLY.replace("  pull_request:", "  pull_request:\n    paths: ['src/**']")
        report, gh = self.report(routes, {"ci.yml": wf, "other.yml": WastedRunTests.PR_ONLY.replace(
            "- run: make", "- run: cargo build")})
        self.assertEqual(report["history"]["state"], "measured")
        self.assertEqual(report["history"]["prSampled"], 2)
        missing = [f for f in report["findings"]
                   if f["id"] == "missing-concurrency" and f["workflow"].endswith("ci.yml")][0]
        # Run 1 overlapped run 2 for 5 of its 10 minutes at 10 runner-min/run.
        self.assertAlmostEqual(missing["estMinutesSaved"], 5.0)
        est = [f["estMinutesSaved"] or 0 for f in report["findings"]]
        self.assertEqual(est, sorted(est, reverse=True))
        # No run touched other.yml: measurable findings report 0, cache ones stay unmeasured.
        other = {f["id"]: f for f in report["findings"] if f["workflow"].endswith("other.yml")}
        self.assertEqual(other["missing-concurrency"]["estMinutesSaved"], 0.0)
        self.assertIsNone(other["no-cache-rust"]["estMinutesSaved"])

    def test_doc_only_estimate(self):
        runs = [run(1, "pull_request", "a", "2026-09-01T00:00:00Z", "2026-09-01T00:06:00Z", "s1", prs=[1]),
                run(2, "pull_request", "b", "2026-09-02T00:00:00Z", "2026-09-02T00:06:00Z", "s2", prs=[2])]
        routes = {"repos/o/r/rules": [],
                  "repos/o/r/actions/runs?": {"workflow_runs": runs},
                  "repos/o/r/actions/runs/": {"jobs": [{"name": "t", "started_at": "2026-09-01T00:00:00Z",
                                                         "completed_at": "2026-09-01T00:06:00Z"}]},
                  "repos/o/r/pulls/1/files": [{"filename": "README.md"}],
                  "repos/o/r/pulls/2/files": [{"filename": "src/a.c"}]}
        report, _ = self.report(routes, {"ci.yml": WastedRunTests.PR_ONLY})
        f = only(report, "unfiltered-pr-workflow")
        self.assertAlmostEqual(f["estMinutesSaved"], 6.0)
        self.assertIn("1/2", f["estNote"])

    def test_remote_mode_reads_workflows_via_contents_api(self):
        import base64
        body = base64.b64encode(WastedRunTests.PR_ONLY.encode()).decode()
        routes = {"repos/o/r/contents/.github/workflows?": [{"name": "ci.yml", "type": "file"}],
                  "repos/o/r/contents/.github/workflows/ci.yml": {"content": body},
                  "repos/o/r/contents?": [{"name": "Makefile", "type": "file"}],
                  "repos/o/r/rules": [], "repos/o/r/actions": 403}
        report, _ = self.report(routes, {}, remote=True)
        self.assertEqual(report["workflowsFound"], 1)
        self.assertIn("missing-concurrency", ids(report))

    def test_remote_repo_without_workflows_is_empty_not_an_error(self):
        report, _ = self.report({"repos/o/r/rules": []}, {}, remote=True)
        self.assertEqual(report["workflowsFound"], 0)
        self.assertIn("nothing to audit", oc.render_text(report))


PUSH_ONLY = "on:\n  push:\n    branches: [main]\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n"


class DefaultBranchStaticTests(unittest.TestCase):
    def conc(self, group="g-${{ github.workflow }}-${{ github.ref }}", cancel=None, base=PUSH_ONLY):
        block = f"concurrency:\n  group: {group}\n"
        if cancel is not None:
            block += f"  cancel-in-progress: {cancel}\n"
        return base.replace("jobs:", block + "jobs:", 1)

    def test_push_only_without_group_is_flagged(self):
        f = only(scan({"w.yml": PUSH_ONLY}), "missing-default-branch-concurrency")
        self.assertIn("cancel-in-progress: false", f["recommendation"])
        self.assertEqual(f["measure"], "default-branch-overlap")

    def test_push_only_with_cancel_true_is_flagged_literal_and_string(self):
        for val in ("true", "'true'", "${{ true }}"):
            self.assertIn("cancel-on-default-branch", ids(scan({"w.yml": self.conc(cancel=val)})), val)

    def test_pr_scoped_cancel_expression_is_safe_but_unknown_expression_is_uncertain(self):
        safe = self.conc(cancel="${{ github.event_name == 'pull_request' }}")
        self.assertEqual(ids(scan({"w.yml": safe})), [])
        unknown = scan({"w.yml": self.conc(cancel="${{ inputs.cancel }}")})
        self.assertIn("uncertain-default-branch-cancel", ids(unknown))
        self.assertNotIn("cancel-on-default-branch", ids(unknown))
        by_ref = self.conc(cancel="${{ github.ref != 'refs/heads/main' }}")
        self.assertEqual(ids(scan({"w.yml": by_ref})), [])

    def test_workflow_that_never_runs_on_default_branch_is_not_asked(self):
        for on in ("on:\n  push:\n    branches: [release]\n", "on:\n  push:\n    tags: ['v*']\n",
                   "on:\n  push:\n    branches-ignore: [main]\n", "on:\n  workflow_dispatch:\n",
                   "on:\n  schedule:\n    - cron: '0 0 * * *'\n",
                   "on:\n  push:\n    branches: ['**', '!main']\n"):
            wf = on + PUSH_ONLY.split("jobs:", 1)[0].replace("on:\n  push:\n    branches: [main]\n", "") \
                + "jobs:" + PUSH_ONLY.split("jobs:", 1)[1]
            self.assertEqual(ids(scan({"w.yml": wf})), [], on)

    def test_branches_ignore_other_branch_still_runs_on_default(self):
        wf = PUSH_ONLY.replace("branches: [main]", "branches-ignore: [dev]")
        self.assertIn("missing-default-branch-concurrency", ids(scan({"w.yml": wf})))

    def test_alternate_default_branch(self):
        wf = PUSH_ONLY.replace("[main]", "[trunk]")
        tmp, root = make_repo({"w.yml": wf})
        with tmp:
            ns = argparse_ns(["scan", "--root", str(root), "--default-branch", "trunk"])
            self.assertIn("missing-default-branch-concurrency", ids(oc.run_scan(ns)))
            ns = argparse_ns(["scan", "--root", str(root)])
            self.assertEqual(ids(oc.run_scan(ns)), [])

    def test_job_level_group_counts_only_when_every_job_has_one(self):
        two = PUSH_ONLY + "  u:\n    runs-on: x\n    steps:\n      - run: make\n"
        job_conc = "    concurrency:\n      group: j-${{ github.workflow }}-${{ github.ref }}\n"
        one = two.replace("  t:\n", "  t:\n" + job_conc, 1)
        self.assertIn("missing-default-branch-concurrency", ids(scan({"w.yml": one})))
        both = one.replace("  u:\n", "  u:\n" + job_conc, 1)
        self.assertEqual(ids(scan({"w.yml": both})), [])
        wf = one.replace(job_conc, job_conc + "      cancel-in-progress: true\n")
        wf = wf.replace("  u:\n", "  u:\n" + job_conc, 1)
        f = only(scan({"w.yml": wf}), "cancel-on-default-branch")
        self.assertEqual(f["job"], "t")

    def test_scalar_group_and_group_quality(self):
        scalar = PUSH_ONLY.replace("jobs:", "concurrency: deploy-prod\njobs:", 1)
        self.assertEqual(ids(scan({"w.yml": scalar})), [])
        ref_only = scan({"w.yml": self.conc(group="${{ github.ref }}")})
        self.assertIn("unsafe-default-branch-group", ids(ref_only))
        unique = scan({"w.yml": self.conc(group="x-${{ github.sha }}")})
        self.assertIn("unsafe-default-branch-group", ids(unique))
        opaque = scan({"w.yml": self.conc(group="${{ inputs.env }}")})
        self.assertIn("uncertain-default-branch-group", ids(opaque))
        self.assertNotIn("unsafe-default-branch-group", ids(opaque))
        self.assertEqual(oc.classify_group("ci-${{ github.ref }}"), ("ref", True))

    def test_pr_workflows_keep_pr_behavior_and_get_no_duplicate_missing_finding(self):
        r = scan({"w.yml": WastedRunTests.PR_ONLY})
        self.assertIn("missing-concurrency", ids(r))
        self.assertNotIn("missing-default-branch-concurrency", ids(r))
        both = WastedRunTests.PR_ONLY.replace("on:\n  pull_request:", "on:\n  pull_request:\n  push:\n    branches: [main]")
        self.assertNotIn("missing-default-branch-concurrency", ids(scan({"w.yml": both})))
        self.assertNotIn("duplicate-push-pr", ids(scan({"w.yml": PUSH_ONLY.replace("branches: [main]", "")})))


def rows_from(spec):
    """spec: [(id, created_min, wall_min)] -> normalized rows at a fixed UTC origin."""
    base = oc._ts("2026-09-01T00:00:00Z")
    from datetime import timedelta
    return [{"id": i, "created": base + timedelta(minutes=c), "start": base + timedelta(minutes=c),
             "end": base + timedelta(minutes=c + w), "conclusion": "success", "wall": float(w)}
            for i, c, w in spec]


class ReplayTests(unittest.TestCase):
    def test_zero_overlap(self):
        rows = rows_from([(1, 0, 10), (2, 20, 10)])
        self.assertEqual(oc.observed_overlap(rows), 0)
        self.assertEqual(oc.replay_queue(rows), (2, []))

    def test_lone_arrival_during_run_is_observed_overlap_but_not_avoided(self):
        rows = rows_from([(1, 0, 10), (2, 5, 10)])
        self.assertEqual(oc.observed_overlap(rows), 1)
        self.assertEqual(oc.replay_queue(rows), (2, []))

    def test_multiple_queued_arrivals_only_newest_survives(self):
        rows = rows_from([(1, 0, 10), (2, 2, 10), (3, 4, 10), (4, 6, 10)])
        self.assertEqual(oc.observed_overlap(rows), 3)
        executed, superseded = oc.replay_queue(rows)
        self.assertEqual((executed, superseded), (2, [2, 3]))

    def test_pending_starts_at_end_of_running_and_blocks_later_arrival(self):
        # 1 runs 0-10; 2 pending runs 10-20; 3 at minute 15 becomes pending (nothing replaced
        # because 2 already started); 4 at 16 supersedes 3.
        rows = rows_from([(1, 0, 10), (2, 5, 10), (3, 15, 10), (4, 16, 10)])
        self.assertEqual(oc.replay_queue(rows), (3, [3]))

    def test_boundary_timestamps_do_not_overlap(self):
        rows = rows_from([(1, 0, 10), (2, 10, 10)])
        self.assertEqual(oc.observed_overlap(rows), 0)
        self.assertEqual(oc.replay_queue(rows), (2, []))

    def test_simultaneous_arrivals_are_ordered_by_id(self):
        rows = rows_from([(2, 0, 10), (1, 0, 10), (3, 0, 10)])
        self.assertEqual(oc.replay_queue(rows), (2, [2]))

    def test_buckets_are_fixed_utc_and_hand_calculated(self):
        # Arrivals at 00:10, 00:50, 01:05, 02:59, 03:00 (UTC).
        rows = rows_from([(i, m, 1) for i, m in enumerate((10, 50, 65, 179, 180))])
        h = oc.bucket_estimate(rows, 20.0, 1)
        self.assertEqual((h["occupiedBuckets"], h["baselineMinutes"], h["estimatedMinutes"],
                          h["savedMinutes"], h["savedPct"]), (4, 100.0, 80.0, 20.0, 20.0))
        t = oc.bucket_estimate(rows, 20.0, 3)
        self.assertEqual((t["occupiedBuckets"], t["estimatedMinutes"], t["savedMinutes"], t["savedPct"]),
                         (2, 40.0, 60.0, 60.0))
        self.assertIn("counterfactual", t["kind"])

    def test_bucket_boundary_across_utc_midnight(self):
        from datetime import timedelta
        base = oc._ts("2026-09-01T23:59:00Z")
        rows = [{"id": i, "created": base + timedelta(minutes=m), "start": base, "end": base,
                 "conclusion": "success", "wall": 1.0} for i, m in enumerate((0, 1))]
        self.assertEqual(oc.bucket_estimate(rows, 10.0, 3)["occupiedBuckets"], 2)


def mrun(i, created, minutes, branch="main", event="push", conclusion="success", attempt=1,
         path=".github/workflows/ci.yml", updated=True):
    from datetime import timedelta
    start = oc._ts(created)
    r = run(i, event, branch, created, (start + timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            f"s{i}", conclusion=conclusion)
    r["path"], r["run_attempt"] = path, attempt
    if not updated:
        r["updated_at"] = None
    return r


def job_route(minutes):
    return {"jobs": [{"name": "a", "started_at": "2026-09-01T00:00:00Z",
                      "completed_at": f"2026-09-01T00:{minutes:02d}:00Z"}]}


class MainStatsTests(unittest.TestCase):
    def stats(self, runs, jobs=None, **kw):
        gh = FakeGitHub({"repos/o/r/actions/runs/": jobs if jobs is not None else 403})
        return oc.main_stats(gh, "o/r", runs, "main", **kw)

    def test_population_filters_and_counts(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10),
                mrun(2, "2026-09-01T00:05:00Z", 10, conclusion="cancelled"),
                mrun(3, "2026-09-01T01:00:00Z", 10, conclusion="failure"),
                mrun(4, "2026-09-01T02:00:00Z", 10, attempt=2),            # rerun: excluded
                mrun(5, "2026-09-01T03:00:00Z", 10, updated=False),         # missing timestamp
                mrun(6, "2026-09-01T04:00:00Z", 10, branch="dev"),          # other branch
                mrun(7, "2026-09-01T05:00:00Z", 10, event="pull_request")]  # other event
        st = self.stats(runs, jobs=job_route(8))
        self.assertEqual((st["pushRuns"], st["originalRuns"], st["rerunAttempts"], st["missingTimestamps"],
                          st["cancelledRuns"], st["eligibleRuns"]), (5, 4, 1, 1, 1, 2))
        self.assertEqual((st["costBasis"], st["perRunMinutes"]), ("job-minutes", 8.0))
        # Runs 1 and 2 overlap observed; replay: 2 is pending (lone) so nothing superseded.
        self.assertEqual((st["observedOverlap"], st["replay"]["superseded"]), (1, 0))

    def test_unequal_job_and_wall_time_and_wall_fallback_is_labeled(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10)]
        st = self.stats(runs, jobs=job_route(30))
        self.assertEqual((st["costBasis"], st["perRunMinutes"]), ("job-minutes", 30.0))
        fallback = self.stats(runs)  # jobs API unreadable
        self.assertEqual((fallback["costBasis"], fallback["perRunMinutes"], fallback["sampledJobRuns"]),
                         ("wall-time", 10.0, 0))

    def test_no_eligible_runs_is_not_measured(self):
        st = self.stats([mrun(1, "2026-09-01T00:00:00Z", 10, conclusion="cancelled")])
        self.assertIsNone(st["perRunMinutes"])
        self.assertIsNone(st["replay"]["estMinutesSaved"])
        self.assertIsNone(st["batching"])

    def test_replay_estimate_uses_job_minutes_not_wall(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10), mrun(2, "2026-09-01T00:02:00Z", 10),
                mrun(3, "2026-09-01T00:04:00Z", 10)]
        st = self.stats(runs, jobs=job_route(20))
        self.assertEqual(st["observedOverlap"], 2)
        self.assertEqual((st["replay"]["superseded"], st["replay"]["estMinutesSaved"]), (1, 20.0))


class DefaultBranchReportTests(unittest.TestCase):
    report = ReportTests.report

    def routes(self, runs, jobs=None, **extra):
        r = {"repos/o/r/rules": [], "repos/o/r/actions/runs?": {"workflow_runs": runs},
             "repos/o/r/actions/runs/": jobs or job_route(10)}
        r.update(extra)
        return r

    def test_push_only_workflow_gets_overlap_and_replay_estimate(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10), mrun(2, "2026-09-01T00:02:00Z", 10),
                mrun(3, "2026-09-01T00:04:00Z", 10)]
        report, _ = self.report(self.routes(runs), {"ci.yml": PUSH_ONLY})
        f = only(report, "missing-default-branch-concurrency")
        self.assertEqual(f["estMinutesSaved"], 10.0)
        self.assertIn("observed: 2 of 3", f["estNote"])
        self.assertIn("1 superseded", f["estNote"])
        self.assertIn("lone arrival", f["estNote"])

    def heavy_report(self, minutes, threshold=None, **kw):
        runs = [mrun(i, f"2026-09-01T{h:02d}:{m:02d}:00Z", 5)
                for i, (h, m) in enumerate([(0, 0), (0, 30), (1, 0), (4, 0)], 1)]
        ns = dict(heavy_main_minutes_per_day=threshold) if threshold is not None else {}
        ns.update(kw)
        wf = WastedRunTests.PR_ONLY.replace("on:\n  pull_request:", "on:\n  pull_request:\n  push:\n    branches: [main]")
        return self.report(self.routes(runs, jobs=job_route(minutes)), {"ci.yml": wf}, **ns)[0]

    def test_heavy_suite_estimates_hourly_and_three_hourly_separately(self):
        # 4 runs x 10 min = 40 runner-min over a 30-day window: below default.
        self.assertNotIn("heavy-default-branch-suite", ids(self.heavy_report(10)))
        report = self.heavy_report(10, threshold=1.0)
        f = only(report, "heavy-default-branch-suite")
        h, t = f["alternatives"]["hourly"], f["alternatives"]["threeHourly"]
        self.assertEqual((h["occupiedBuckets"], h["estimatedMinutes"], h["savedMinutes"], h["savedPct"]),
                         (3, 30.0, 10.0, 25.0))
        self.assertEqual((t["occupiedBuckets"], t["estimatedMinutes"], t["savedMinutes"], t["savedPct"]),
                         (2, 20.0, 20.0, 50.0))
        self.assertEqual(f["estMinutesSaved"], 10.0)  # canonical = hourly, never hourly + 3 h
        self.assertTrue(f["reportOnly"])
        self.assertFalse(f["applyEligible"])
        self.assertIn("schedule", f["recommendation"])
        self.assertIn("never part of --apply", f["recommendation"])
        self.assertIn("counterfactual", f["estNote"])
        self.assertIn("of 40.0 min", f["estNote"])

    def test_threshold_boundary_is_inclusive(self):
        # 4 runs x 10 min / 30 days = 1.3333 min/day.
        daily = 40.0 / 30
        self.assertIn("heavy-default-branch-suite", ids(self.heavy_report(10, threshold=daily)))
        self.assertNotIn("heavy-default-branch-suite", ids(self.heavy_report(10, threshold=daily + 0.01)))
        self.assertEqual(oc.DEFAULT_HEAVY_MAIN_MINUTES_PER_DAY, 300.0)

    def test_pr_only_and_push_only_workflows_are_never_heavy(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 5)]
        for wf in (PUSH_ONLY, WastedRunTests.PR_ONLY):
            report = self.report(self.routes(runs, jobs=job_route(50)), {"ci.yml": wf},
                                 heavy_main_minutes_per_day=0.0)[0]
            self.assertNotIn("heavy-default-branch-suite", ids(report))

    def test_capped_sample_is_visible_and_uses_observed_span(self):
        report = self.heavy_report(10, threshold=1.0, runs=4)
        h = report["history"]
        self.assertTrue(h["sampleCapped"])
        self.assertLess(h["windowDays"], h["requestedDays"])
        f = only(report, "heavy-default-branch-suite")
        self.assertIn("sample capped at 4 runs", f["estNote"])
        self.assertIn("Sample CAPPED", oc.render_text(report))
        full = self.heavy_report(10, threshold=1.0, runs=50)
        self.assertFalse(full["history"]["sampleCapped"])
        self.assertEqual(full["history"]["windowDays"], 30.0)

    def test_wall_time_fallback_is_labeled_not_job_minutes(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10)]
        routes = self.routes(runs)
        routes["repos/o/r/actions/runs/"] = 403
        wf = WastedRunTests.PR_ONLY.replace("on:\n  pull_request:", "on:\n  pull_request:\n  push:\n    branches: [main]")
        rep = self.report(routes, {"ci.yml": wf}, heavy_main_minutes_per_day=0.1)[0]
        f = only(rep, "heavy-default-branch-suite")
        self.assertIn("wall-time fallback, not job-minutes", f["estNote"])

    def test_unreadable_history_and_no_history_degrade(self):
        for kw, routes in (({}, {"repos/o/r/actions": 403, "repos/o/r/rules": []}),
                           ({"no_history": True}, {"repos/o/r/rules": []})):
            report = self.report(routes, {"ci.yml": PUSH_ONLY}, **kw)[0]
            self.assertEqual(report["history"]["state"], "not measured")
            f = only(report, "missing-default-branch-concurrency")
            self.assertIsNone(f["estMinutesSaved"])
            self.assertNotIn("heavy-default-branch-suite", ids(report))
            self.assertIn("not measured", oc.render_text(report))

    def test_unreadable_job_samples_fall_back_without_failing(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10), mrun(2, "2026-09-01T00:05:00Z", 10)]
        routes = self.routes(runs)
        routes["repos/o/r/actions/runs/"] = 403
        report = self.report(routes, {"ci.yml": PUSH_ONLY})[0]
        self.assertEqual(report["history"]["defaultBranchRuns"][".github/workflows/ci.yml"]["costBasis"],
                         "wall-time")

    def test_two_workflows_are_measured_independently(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10), mrun(2, "2026-09-01T00:01:00Z", 10),
                mrun(3, "2026-09-01T00:02:00Z", 10),
                mrun(4, "2026-09-01T00:00:00Z", 10, path=".github/workflows/b.yml"),
                mrun(5, "2026-09-01T00:30:00Z", 10, path=".github/workflows/b.yml")]
        report = self.report(self.routes(runs), {"ci.yml": PUSH_ONLY, "b.yml": PUSH_ONLY})[0]
        by = {f["workflow"]: f for f in report["findings"] if f["id"] == "missing-default-branch-concurrency"}
        self.assertEqual(by[".github/workflows/ci.yml"]["estMinutesSaved"], 10.0)
        self.assertEqual(by[".github/workflows/b.yml"]["estMinutesSaved"], 0.0)

    def test_cancelled_default_branch_runs_are_reported_on_cancel_finding(self):
        runs = [mrun(1, "2026-09-01T00:00:00Z", 10, conclusion="cancelled"),
                mrun(2, "2026-09-01T01:00:00Z", 10)]
        wf = PUSH_ONLY.replace("jobs:", "concurrency:\n  group: g-${{ github.workflow }}-${{ github.ref }}\n"
                                       "  cancel-in-progress: true\njobs:", 1)
        report = self.report(self.routes(runs), {"ci.yml": wf})[0]
        f = only(report, "cancel-on-default-branch")
        self.assertIn("1 of 2 default-branch push run(s)", f["estNote"])
        self.assertIsNone(f["estMinutesSaved"])

    def test_summary_counts_default_branch_savings_once_and_critical_first(self):
        crit = {"id": "c", "severity": "critical", "workflow": "a.yml", "estMinutesSaved": None}
        a = {"id": "heavy", "severity": "low", "workflow": "w.yml", "estMinutesSaved": 40.0,
             "estDefaultBranchMinutes": 40.0}
        b = {"id": "overlap", "severity": "medium", "workflow": "w.yml", "estMinutesSaved": 15.0,
             "estDefaultBranchMinutes": 15.0}
        c = {"id": "pr", "severity": "medium", "workflow": "w.yml", "estMinutesSaved": 30.0}
        d = {"id": "mixed", "severity": "medium", "workflow": "x.yml", "estMinutesSaved": 12.0,
             "estDefaultBranchMinutes": 2.0}
        self.assertEqual(oc.summarize([a, b, c, d, crit])["estMinutesSavedTotal"], 82.0)
        ranked = oc.rank([a, b, c, crit])
        self.assertEqual(ranked[0]["id"], "c")

    def test_json_and_text_serialization(self):
        report = self.heavy_report(10, threshold=1.0)
        data = json.loads(json.dumps(report, default=str))
        self.assertIn("alternatives", only(data, "heavy-default-branch-suite"))
        text = oc.render_text(report)
        self.assertIn("heavy-default-branch-suite", text)
        self.assertIn("alternatives, not additive", text)


class PerWorkflowSamplingTests(unittest.TestCase):
    """Issue #573: per-workflow sampling, true totals, scaling, job spread."""

    SENTINEL = "on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\njobs:\n  s:\n    runs-on: x\n    steps:\n      - run: true\n"

    def setUp(self):
        self.sent = [mrun(100 + i, f"2026-09-01T00:{i:02d}:00Z", 1, event="workflow_run",
                          path=".github/workflows/sentinel.yml") for i in range(5)]
        self.ci = [mrun(i, f"2026-09-02T00:{i:02d}:00Z", 10, event="pull_request", branch=f"b{i}")
                   for i in range(1, 4)]

    def report(self, runs_per_wf, totals, jobs_by_run=None, max_runs=3):
        routes = {"repos/o/r/rules": [],
                  "repos/o/r/actions/workflows/ci.yml/runs": {"workflow_runs": runs_per_wf["ci"], "total_count": totals["ci"]},
                  "repos/o/r/actions/workflows/sentinel.yml/runs": {"workflow_runs": runs_per_wf["sentinel"], "total_count": totals["sentinel"]},
                  "repos/o/r/actions/runs/": jobs_by_run or job_route(10)}
        tmp, root = make_repo({"ci.yml": WastedRunTests.PR_ONLY, "sentinel.yml": self.SENTINEL})
        with tmp:
            ns = type("A", (), dict(repo="o/r", root=str(root), remote=False, default_branch=None,
                                    runs=max_runs, days=30, no_history=False, json=True))()
            return oc.run_report(ns, gh=FakeGitHub(routes))

    def test_cheap_workflow_cannot_crowd_out_expensive_one(self):
        report = self.report({"ci": self.ci, "sentinel": self.sent[:3]}, {"ci": 3, "sentinel": 5000})
        pw = report["history"]["perWorkflow"]
        self.assertEqual(pw[".github/workflows/ci.yml"]["runs"], 3)
        self.assertEqual(pw[".github/workflows/sentinel.yml"]["runs"], 3)
        self.assertEqual(pw[".github/workflows/sentinel.yml"]["totalRuns"], 5000)
        self.assertTrue(pw[".github/workflows/sentinel.yml"]["sampleCapped"])
        self.assertFalse(pw[".github/workflows/ci.yml"]["sampleCapped"])
        self.assertTrue(report["history"]["sampleCapped"])

    def test_total_minutes_scale_by_true_run_count(self):
        report = self.report({"ci": self.ci, "sentinel": self.sent[:3]}, {"ci": 300, "sentinel": 3})
        ci = report["history"]["perWorkflow"][".github/workflows/ci.yml"]
        self.assertEqual(ci["scale"], 100.0)
        self.assertEqual(ci["totalRunnerMinutes"], 10.0 * 300)

    def test_text_says_sample_is_capped(self):
        report = self.report({"ci": self.ci, "sentinel": self.sent[:3]}, {"ci": 300, "sentinel": 3})
        text = oc.render_text(report)
        self.assertIn("sampled 3 of 300 runs", text)
        self.assertIn("CAPPED", text)

    def test_job_spread_median_and_p90_over_more_than_five_runs(self):
        runs = [mrun(i, f"2026-09-02T00:{i:02d}:00Z", 10, event="pull_request", branch=f"b{i}")
                for i in range(1, 11)]
        report = self.report({"ci": runs, "sentinel": self.sent[:3]}, {"ci": 10, "sentinel": 3},
                             max_runs=10)
        ci = report["history"]["perWorkflow"][".github/workflows/ci.yml"]
        self.assertEqual(ci["sampledRuns"], 10)
        self.assertEqual(ci["jobSpread"]["a"]["n"], 10)

    def test_percentile(self):
        self.assertEqual(oc._percentile([1, 1, 1, 1, 1, 1, 1, 1, 1, 30], 50), 1)
        self.assertEqual(oc._percentile([1, 1, 1, 1, 1, 1, 1, 1, 1, 30], 90), 1)
        self.assertEqual(oc._percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 30], 90), 9)
        self.assertEqual(oc._percentile([4], 90), 4)

    def test_falls_back_to_repo_wide_listing_when_per_workflow_unreadable(self):
        tmp, root = make_repo({"ci.yml": WastedRunTests.PR_ONLY})
        routes = {"repos/o/r/rules": [], "repos/o/r/actions/workflows/": 404,
                  "repos/o/r/actions/runs?": {"workflow_runs": self.ci},
                  "repos/o/r/actions/runs/": job_route(10)}
        with tmp:
            ns = type("A", (), dict(repo="o/r", root=str(root), remote=False, default_branch=None,
                                    runs=50, days=30, no_history=False, json=True))()
            report = oc.run_report(ns, gh=FakeGitHub(routes))
        self.assertFalse(report["history"]["perWorkflowSampling"])
        self.assertEqual(report["history"]["runs"], 3)


class ReadOnlyAndCliTests(unittest.TestCase):
    def test_every_github_call_is_a_get(self):
        with patch.object(oc.subprocess, "run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess([], 0, stdout="{}", stderr="")
            oc.GitHub().api("repos/o/r")
        argv = mock_run.call_args[0][0]
        self.assertEqual(argv[:4], ["gh", "api", "--method", "GET"])

    def test_cli_scan_json_on_repo_without_workflows(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, str(HELPER), "scan", "--root", tmp, "--json"],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["workflowsFound"], 0)

    def test_cli_text_report_on_this_repo(self):
        result = subprocess.run([sys.executable, str(HELPER), "scan", "--root", str(ROOT)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CI OPTIMIZATION REPORT", result.stdout)


if __name__ == "__main__":
    loader = unittest.defaultTestLoader
    suite = unittest.TestSuite()
    for case in (YamlReaderTests, GlobTests, RequiredCheckSafetyTests, UnderFilterTests, CacheTests,
                 WastedRunTests, DefaultBranchStaticTests, ReplayTests, MainStatsTests,
                 ReportTests, DefaultBranchReportTests, PerWorkflowSamplingTests,
                 ReadOnlyAndCliTests):
        suite.addTests(loader.loadTestsFromTestCase(case))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failed = len(result.failures) + len(result.errors)
    print(f"Passed: {result.testsRun - failed}")
    print(f"Failed: {failed}")
    sys.exit(0 if result.wasSuccessful() else 1)

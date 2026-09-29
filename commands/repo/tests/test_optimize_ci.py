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
                 WastedRunTests, ReportTests, ReadOnlyAndCliTests):
        suite.addTests(loader.loadTestsFromTestCase(case))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failed = len(result.failures) + len(result.errors)
    print(f"Passed: {result.testsRun - failed}")
    print(f"Failed: {failed}")
    sys.exit(0 if result.wasSuccessful() else 1)

#!/usr/bin/env python3
"""Behavioral tests for policy resolution, previews, and GitHub publication.

All GitHub calls use an in-memory API double; this suite cannot publish to GitHub.
"""

import base64
import copy
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("org_policy", ROOT / "scripts/repo/repo-org-policy.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
DEFAULT = json.loads((ROOT / "policies/default.json").read_text())


class FakeGitHub:
    def __init__(self):
        self.source_revision = "a" * 40
        self.source = {"policies/default.json": policy.dump(DEFAULT)}
        self.target = "example/.github"
        self.base = "b" * 40
        self.files = {"README.md": "Preserve me\n"}
        self.exists = True
        self.calls = []
        self.refs = {}
        self.commits = {}
        self.trees = {}
        self.prs = []
        self.owner_type = "Organization"

    @property
    def writes(self):
        return [call for call in self.calls if call[1] != "GET"]

    def api(self, endpoint, method="GET", payload=None, missing_ok=False):
        self.calls.append((endpoint, method, copy.deepcopy(payload)))
        parsed = urlparse(endpoint)
        route = parsed.path
        query = parse_qs(parsed.query)
        source_root = "repos/rjwalters/repo"
        target_root = f"repos/{self.target}"
        if route == f"{source_root}/commits/HEAD":
            return {"sha": self.source_revision}
        if route.startswith(f"{source_root}/contents/"):
            if query["ref"] != [self.source_revision]:
                raise AssertionError("Source file read outside the resolved revision")
            name = route.split("/contents/", 1)[1]
            return self.file_response(self.source.get(name))
        if route == target_root:
            return {"default_branch": "trunk"} if self.exists else None
        if route == f"{target_root}/commits/trunk":
            return {"sha": self.base, "commit": {"tree": {"sha": "base-tree"}}}
        if route.startswith(f"{target_root}/contents/"):
            name = route.split("/contents/", 1)[1]
            revision = query["ref"][0]
            files = self.files if revision == self.base else self.commits[revision]["files"]
            return self.file_response(files.get(name))
        if route == "users/example":
            return {"type": self.owner_type}
        if route == "user":
            return {"login": "example"}
        if route in ("orgs/example/repos", "user/repos"):
            assert method == "POST" and not self.exists
            self.exists = True
            return {"name": ".github"}
        if route.startswith(f"{target_root}/git/ref/heads/"):
            branch = route.split("/git/ref/heads/", 1)[1]
            return {"object": {"sha": self.refs[branch]}} if branch in self.refs else None
        if route == f"{target_root}/git/trees":
            assert method == "POST" and payload["base_tree"] == "base-tree"
            files = dict(self.files)
            for entry in payload["tree"]:
                files[entry["path"]] = entry["content"]
            sha = policy.digest(policy.dump(files))[:40]
            self.trees[sha] = files
            return {"sha": sha}
        if route == f"{target_root}/git/commits":
            assert method == "POST"
            sha = policy.digest(policy.dump(payload))[:40]
            self.commits[sha] = {"parents": [{"sha": s} for s in payload["parents"]],
                                 "files": self.trees[payload["tree"]]}
            return {"sha": sha}
        if route.startswith(f"{target_root}/git/commits/"):
            return self.commits[route.rsplit("/", 1)[1]]
        if route.startswith(f"{target_root}/compare/"):
            sha = route.split("...", 1)[1]
            changed = [name for name, content in self.commits[sha]["files"].items()
                       if self.files.get(name) != content]
            return {"files": [{"filename": name} for name in changed]}
        if route == f"{target_root}/git/refs":
            assert method == "POST"
            self.refs[payload["ref"].removeprefix("refs/heads/")] = payload["sha"]
            return {}
        if route == f"{target_root}/pulls":
            if method == "GET":
                branch = query["head"][0].split(":", 1)[1]
                return [pr for pr in self.prs if pr["head"] == branch]
            assert method == "POST" and payload["base"] == "trunk"
            self.prs.append({"html_url": "https://github.com/example/.github/pull/1", "head": payload["head"]})
            return self.prs[-1]
        raise AssertionError(f"Unexpected API call: {method} {endpoint}")

    @staticmethod
    def file_response(content):
        if content is None:
            return None
        return {"type": "file", "encoding": "base64",
                "content": base64.b64encode(content.encode()).decode()}


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()

    def plan(self, **kwargs):
        return policy.make_plan(self.api, "example/client", **kwargs)

    def test_preview_is_read_only_and_has_agreed_age_policy(self):
        plan = self.plan()
        config = json.loads(plan["after"]["renovate-config.json"])
        self.assertEqual(config["minimumReleaseAge"], "14 days")
        self.assertEqual(config["vulnerabilityAlerts"]["minimumReleaseAge"], "1 day")
        self.assertFalse(config["automerge"])
        self.assertFalse(config["vulnerabilityAlerts"]["automerge"])
        self.assertEqual(self.api.writes, [])
        metadata = json.loads(plan["after"]["repo-policy.json"])
        self.assertEqual(metadata["source"]["revision"], self.api.source_revision)
        self.assertEqual(metadata["dependencies"]["renovatePreset"], "github>example/.github:renovate-config")
        self.assertNotIn("renovate", metadata["dependencies"])

    def test_owner_override_changes_security_delay_without_mutating_defaults(self):
        self.api.source["policies/organizations/example.json"] = policy.dump({
            "dependencies": {"renovate": {"vulnerabilityAlerts": {"minimumReleaseAge": None}}}})
        plan = self.plan()
        config = json.loads(plan["after"]["renovate-config.json"])
        self.assertIsNone(config["vulnerabilityAlerts"]["minimumReleaseAge"])
        self.assertEqual(config["minimumReleaseAge"], "14 days")
        self.assertEqual(DEFAULT["dependencies"]["renovate"]["vulnerabilityAlerts"]["minimumReleaseAge"], "1 day")
        self.assertIn("policies/organizations/example.json", plan["source"]["files"])

    def test_arrays_replace_instead_of_union(self):
        self.assertEqual(policy.merge({"a": [1, 2]}, {"a": [3]}), {"a": [3]})

    def test_unknown_preferences_fail_instead_of_silently_ignoring(self):
        self.api.source["policies/organizations/example.json"] = '{"dependencise": {}}'
        with self.assertRaises(policy.PolicyError):
            self.plan()
        self.assertEqual(self.api.writes, [])

    def test_invalid_policy_types_are_rejected(self):
        for override in ({"schemaVersion": True}, {"dependencies": {"dependabotAlerts": "true"}},
                         {"dependencies": {"renovate": {"minimumReleaseAge": "tomorrow"}}},
                         {"dependencies": {"renovate": {"vulnerabilityAlerts": False}}}):
            with self.subTest(override=override), self.assertRaises(policy.PolicyError):
                policy.validate(policy.merge(DEFAULT, override))

    def test_missing_canonical_default_is_an_error(self):
        self.api.source.clear()
        with self.assertRaisesRegex(policy.PolicyError, "publish"):
            self.plan()

    def test_absent_org_requires_explicit_visibility(self):
        self.api.exists = False
        with self.assertRaisesRegex(policy.PolicyError, "absent or inaccessible"):
            self.plan()
        self.assertEqual(self.plan(create_repository="private")["createRepository"], "private")
        self.assertEqual(self.api.writes, [])

    def test_apply_preserves_unrelated_files_and_opens_pr_without_changing_default(self):
        plan = self.plan()
        result = policy.apply_plan(self.api, plan)
        self.assertEqual(result, "https://github.com/example/.github/pull/1")
        committed = next(iter(self.api.commits.values()))["files"]
        self.assertEqual(committed["README.md"], "Preserve me\n")
        self.assertEqual(set(committed), {"README.md"} | policy.MANAGED_FILES)
        self.assertEqual(self.api.files, {"README.md": "Preserve me\n"})
        self.assertFalse(any(method in ("PATCH", "PUT", "DELETE") for _, method, _ in self.api.writes))

    def test_retry_reuses_branch_and_pr_without_more_writes(self):
        plan = self.plan()
        first = policy.apply_plan(self.api, plan)
        count = len(self.api.writes)
        self.assertEqual(policy.apply_plan(self.api, plan), first)
        self.assertEqual(len(self.api.writes), count)

    def test_different_clients_reuse_the_same_organization_pr(self):
        first = self.plan()
        url = policy.apply_plan(self.api, first)
        count = len(self.api.writes)
        second = policy.make_plan(self.api, "EXAMPLE/another-client")
        self.assertEqual(policy.apply_plan(self.api, second), url)
        self.assertEqual(len(self.api.writes), count)

    def test_retry_does_not_accept_unrelated_changes_on_existing_branch(self):
        plan = self.plan()
        policy.apply_plan(self.api, plan)
        next(iter(self.api.commits.values()))["files"]["README.md"] = "Unexpected change"
        count = len(self.api.writes)
        with self.assertRaisesRegex(policy.PolicyError, "unrelated changes"):
            policy.apply_plan(self.api, plan)
        self.assertEqual(len(self.api.writes), count)

    def test_changed_target_rejects_stale_preview_before_writes(self):
        plan = self.plan()
        self.api.base = "c" * 40
        with self.assertRaisesRegex(policy.PolicyError, "changed after preview"):
            policy.apply_plan(self.api, plan)
        self.assertEqual(self.api.writes, [])

    def test_changed_source_rejects_stale_preview_before_writes(self):
        plan = self.plan()
        self.api.source_revision = "d" * 40
        with self.assertRaisesRegex(policy.PolicyError, "changed after preview"):
            policy.apply_plan(self.api, plan)
        self.assertEqual(self.api.writes, [])

    def test_no_op_after_merged_policy_even_with_unrelated_canonical_commit(self):
        plan = self.plan()
        self.api.files.update(plan["after"])
        self.api.source_revision = "d" * 40
        current = self.plan()
        self.assertFalse(policy.changed(current))
        self.assertIn("nothing to publish", policy.apply_plan(self.api, current))
        self.assertEqual(self.api.writes, [])

    def test_organization_hand_edit_is_visible_drift(self):
        plan = self.plan()
        self.api.files.update(plan["after"])
        config = json.loads(self.api.files["renovate-config.json"])
        config["minimumReleaseAge"] = "0 days"
        self.api.files["renovate-config.json"] = policy.dump(config)
        self.assertTrue(policy.changed(self.plan()))

    def test_edited_plan_rejected_even_if_hash_recomputed(self):
        plan = self.plan()
        plan["after"]["renovate-config.json"] = '{}\n'
        plan["digest"] = policy.digest(policy.dump({k: v for k, v in plan.items() if k != "digest"}))
        with self.assertRaisesRegex(policy.PolicyError, "changed after preview"):
            policy.apply_plan(self.api, plan)
        self.assertEqual(self.api.writes, [])

    def test_local_source_is_preview_only(self):
        plan = self.plan(source_dir=ROOT)
        with self.assertRaisesRegex(policy.PolicyError, "preview-only"):
            policy.apply_plan(self.api, plan)
        self.assertEqual(self.api.writes, [])

    def test_create_organization_repo_uses_explicit_visibility(self):
        self.api.exists = False
        policy.apply_plan(self.api, self.plan(create_repository="private"))
        endpoint, _, payload = self.api.writes[0]
        self.assertEqual(endpoint, "orgs/example/repos")
        self.assertTrue(payload["private"])
        self.assertTrue(payload["auto_init"])

    def test_personal_owner_creation_uses_user_endpoint(self):
        self.api.owner_type = "User"
        self.api.exists = False
        policy.apply_plan(self.api, self.plan(create_repository="public"))
        self.assertEqual(self.api.writes[0][0], "user/repos")

    def test_client_origin_resolution(self):
        for url in ("git@github.com:example/client.git", "https://github.com/example/client.git",
                    "ssh://git@github.com/example/client.git"):
            with self.subTest(url=url), patch.object(policy.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, url + "\n", "")):
                self.assertEqual(policy.client_repo(), "example/client")
        with patch.object(policy.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 0, "https://gitlab.com/example/client.git", "")):
            with self.assertRaises(policy.PolicyError):
                policy.client_repo()

    def test_client_target_path_injection_rejected(self):
        for value in ("example/../x", "example", "../.github", "example/repo?x=y"):
            with self.subTest(value=value), self.assertRaises(policy.PolicyError):
                policy.repo_name(value)

    def test_github_403_is_not_missing_and_explicit_host_is_used(self):
        with patch.object(policy.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 1, "", "gh: Forbidden (HTTP 403)")) as run:
            with self.assertRaises(policy.PolicyError):
                policy.GitHub().api("repos/example/.github", missing_ok=True)
            self.assertIn("github.com", run.call_args.args[0])

    def test_github_404_can_be_missing(self):
        with patch.object(policy.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")):
            self.assertIsNone(policy.GitHub().api("repos/example/.github", missing_ok=True))

    def test_github_payload_is_structured_not_shell_interpreted(self):
        payload = {"body": "line one\n$(touch /tmp/unwanted) `id`"}
        with patch.object(policy.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 0, "{}", "")) as run:
            policy.GitHub().api("repos/example/.github/pulls", "POST", payload)
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), payload)
            self.assertNotIn("shell", run.call_args.kwargs)

    def test_apply_cli_requires_opt_in_without_reading_plan(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/repo/repo-org-policy.py"),
                                 "apply", "--plan", "/missing/plan.json"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--yes", result.stderr)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PolicyTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failed = len(result.failures) + len(result.errors)
    print(f"Passed: {result.testsRun - failed}")
    print(f"Failed: {failed}")
    sys.exit(0 if result.wasSuccessful() else 1)

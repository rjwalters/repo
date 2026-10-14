"""Tests for policies/validate-dependabot.py, run in-process with mutations."""

import copy
import importlib.util
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("validate_dependabot", ROOT / "policies/validate-dependabot.py")
vd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vd)


class ValidateDependabotTests(unittest.TestCase):
    def setUp(self):
        self.profiles = vd.load_profiles()
        self.doc = yaml.safe_load((ROOT / ".github/dependabot.yml").read_text())

    def run_checks(self, profiles=None, doc=None):
        return vd.run(profiles if profiles is not None else self.profiles, doc if doc is not None else self.doc)

    def test_committed_files_pass(self):
        self.assertEqual(self.run_checks(), [])

    def test_routine_cooldown_mutated_fails(self):
        profiles = copy.deepcopy(self.profiles)
        profiles[0][1]["dependencies"]["dependabot"]["cooldown"]["routineDays"] = 7
        self.assertTrue(self.run_checks(profiles))

    def test_security_cooldown_mutated_fails(self):
        profiles = copy.deepcopy(self.profiles)
        profiles[0][1]["dependencies"]["dependabot"]["cooldown"]["securityDays"] = 3
        self.assertTrue(any("securityDays" in e for e in self.run_checks(profiles)))

    def test_rendered_default_days_mismatch_fails(self):
        doc = copy.deepcopy(self.doc)
        doc["updates"][0]["cooldown"]["default-days"] = 7
        self.assertTrue(any("default-days" in e for e in self.run_checks(doc=doc)))

    def test_missing_default_days_fails(self):
        doc = copy.deepcopy(self.doc)
        del doc["updates"][0]["cooldown"]["default-days"]
        self.assertTrue(any("default-days" in e for e in self.run_checks(doc=doc)))

    def test_non_integer_default_days_fails(self):
        for bad in ("14", 14.0, True, None):
            doc = copy.deepcopy(self.doc)
            doc["updates"][0]["cooldown"]["default-days"] = bad
            self.assertTrue(self.run_checks(doc=doc), bad)

    def test_structural_failures(self):
        self.assertTrue(self.run_checks(doc={"version": 1, "updates": []}))
        self.assertTrue(self.run_checks(doc={"version": 2, "updates": []}))
        doc = copy.deepcopy(self.doc)
        del doc["updates"][0]["schedule"]
        self.assertTrue(self.run_checks(doc=doc))


if __name__ == "__main__":
    unittest.main()

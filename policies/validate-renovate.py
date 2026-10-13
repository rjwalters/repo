#!/usr/bin/env python3
"""Validate every effective canonical profile with a native Renovate validator.

A profile whose provider is not renovate is checked by validate() alone.

Usage: python3 policies/validate-renovate.py [validator command ...]
Defaults to renovate-config-validator from PATH. No GitHub access is needed.
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("org_policy", ROOT / "scripts/repo/repo-org-policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def main():
    command = sys.argv[1:] or ["renovate-config-validator"]
    default = json.loads((ROOT / "policies/default.json").read_text())
    profiles = [("default", default)]
    for profile in sorted((ROOT / "policies/organizations").glob("*.json")):
        if profile.stem != profile.stem.lower():
            raise policy.PolicyError(f"Owner filename must be lowercase: {profile.name}")
        policy.repo_name(profile.stem + "/.github")
        override = json.loads(profile.read_text())
        if not isinstance(override, dict):
            raise policy.PolicyError(f"Owner override must be an object: {profile.name}")
        profiles.append((profile.stem, policy.merge(default, override)))
    with tempfile.TemporaryDirectory(prefix="repo-policy-validation-") as scratch:
        for name, value in profiles:
            policy.validate(value)
            if value["dependencies"]["provider"] != "renovate":
                print(f"Skipping {name}: provider {value['dependencies']['provider']} has no Renovate preset", flush=True)
                continue
            preset = Path(scratch) / (name + ".json")
            preset.write_text(policy.dump(value["dependencies"]["renovate"]))
            print(f"Validating {name}", flush=True)
            subprocess.run(command + ["--strict", str(preset)], check=True)


if __name__ == "__main__":
    main()

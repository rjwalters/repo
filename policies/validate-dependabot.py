#!/usr/bin/env python3
"""Validate the canonical Dependabot policy and the committed dependabot.yml.

Checks, offline (no GitHub access, no network):
  1. policy.validate() on the default profile and every organization profile.
  2. On each effective Dependabot profile: cooldown.routineDays == 14 and
     cooldown.securityDays == 1. The one-day security value lives only in the
     policy: the rendered dependabot.yml carries no security key.
  3. Structural schema check of .github/dependabot.yml (version 2, non-empty
     updates[], each with package-ecosystem, schedule.interval and an integer
     cooldown.default-days), and default-days == routineDays for every entry.

Usage: python3 policies/validate-dependabot.py [path/to/dependabot.yml]
Requires PyYAML.
"""

import importlib.util
import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("org_policy", ROOT / "scripts/repo/repo-org-policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

ROUTINE_DAYS = 14
SECURITY_DAYS = 1


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def load_profiles(root=ROOT):
    default = json.loads((root / "policies/default.json").read_text())
    profiles = [("default", default)]
    for profile in sorted((root / "policies/organizations").glob("*.json")):
        if profile.stem != profile.stem.lower():
            raise policy.PolicyError(f"Owner filename must be lowercase: {profile.name}")
        policy.repo_name(profile.stem + "/.github")
        override = json.loads(profile.read_text())
        if not isinstance(override, dict):
            raise policy.PolicyError(f"Owner override must be an object: {profile.name}")
        profiles.append((profile.stem, policy.merge(default, override)))
    return profiles


def check_profile(name, value):
    """Return (list of errors, routineDays or None) for one effective profile."""
    errors = []
    try:
        policy.validate(value)
    except policy.PolicyError as exc:
        return [f"{name}: validate() failed: {exc}"], None
    deps = value["dependencies"]
    if deps["provider"] != "dependabot":
        return errors, None
    cooldown = deps.get("dependabot", {}).get("cooldown", {})
    if cooldown.get("routineDays") != ROUTINE_DAYS:
        errors.append(f"{name}: cooldown.routineDays must be {ROUTINE_DAYS}, got {cooldown.get('routineDays')!r}")
    if cooldown.get("securityDays") != SECURITY_DAYS:
        errors.append(f"{name}: cooldown.securityDays must be {SECURITY_DAYS}, got {cooldown.get('securityDays')!r}")
    return errors, cooldown.get("routineDays")


def check_rendered(doc, routine_days):
    """Structural check of a parsed dependabot.yml plus the cooldown match."""
    errors = []
    if not isinstance(doc, dict) or doc.get("version") != 2:
        return ["dependabot.yml: version must be 2"]
    updates = doc.get("updates")
    if not isinstance(updates, list) or not updates:
        return ["dependabot.yml: updates must be a non-empty list"]
    for index, entry in enumerate(updates):
        label = f"updates[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"dependabot.yml: {label} must be a mapping")
            continue
        label += f" ({entry.get('package-ecosystem')})"
        if not entry.get("package-ecosystem"):
            errors.append(f"dependabot.yml: {label} missing package-ecosystem")
        schedule = entry.get("schedule")
        if not isinstance(schedule, dict) or not schedule.get("interval"):
            errors.append(f"dependabot.yml: {label} missing schedule.interval")
        cooldown = entry.get("cooldown")
        days = cooldown.get("default-days") if isinstance(cooldown, dict) else None
        if not is_int(days):
            errors.append(f"dependabot.yml: {label} cooldown.default-days must be an integer, got {days!r}")
        elif days != routine_days:
            errors.append(f"dependabot.yml: {label} default-days {days} != policy routineDays {routine_days}")
    return errors


def run(profiles, doc):
    errors = []
    routine = None
    for name, value in profiles:
        profile_errors, days = check_profile(name, value)
        errors += profile_errors
        if name == "default":
            routine = days
    if routine is None:
        errors.append("default: no dependabot routineDays to compare dependabot.yml against")
    else:
        errors += check_rendered(doc, routine)
    return errors


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".github/dependabot.yml"
    errors = run(load_profiles(), yaml.safe_load(path.read_text()))
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("Dependabot policy and dependabot.yml are consistent")


if __name__ == "__main__":
    main()

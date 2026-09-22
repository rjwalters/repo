# Canonical organization preferences

This directory in **rjwalters/repo** is authoritative. `default.json` holds
shared defaults; `organizations/<lowercase-github-owner>.json` holds optional
owner overrides. Both are read at the same default-branch commit. There is no
registry of client repos to maintain, and no organization is changed merely
because these files exist.

For example, an organization choosing immediate security fixes would add
`policies/organizations/example-org.json` containing:

```json
{
  "dependencies": {
    "renovate": {
      "vulnerabilityAlerts": {
        "minimumReleaseAge": null
      }
    }
  }
}
```

Objects merge recursively. Arrays and scalars replace, including Renovate
`packageRules` and `extends` arrays; include every desired entry when overriding
an array. The resulting policy must pass the helper's structural validation
and Renovate's native config validator. `dependencies.renovate` is native
Renovate configuration, so timing and automerge preferences have one definition.

The baseline deliberately separates two decisions:

- **Eligibility:** routine versions age for 14 days; advisory-backed security
  fixes age for one day. A security claim in release notes is not automatically
  an advisory. Emergency zero-delay overrides are explicitly authorized and
  scoped to the affected dependency/client.
- **Merging:** automerge is off until a repository has suitable required checks
  and its owner opts in. A shorter cooldown does not waive tests or review.

Release-age support depends on datasource timestamps and update type. Audit
package-manager/lockfile age controls as well: Renovate alone cannot guarantee
the age of every transitive dependency. Verify one-day security behavior with
the deployed Renovate version and package manager during the pilot. Keep
security alerts enabled throughout migration. Turn off Dependabot's security
PR generation only after Renovate's fix coverage is verified for that client.

## Distribution from a client repository

Install Repo Skills normally, then invoke `/repo:org-policy --install` in a
client. The helper fetches the current canonical files from GitHub; it does
not depend on a local source clone or ship a potentially stale policy bundle.
An optional `--repo OWNER/PROJECT` selects a client explicitly.

The helper previews and opens a PR changing only these files in `OWNER/.github`:

| File | Contents |
|------|----------|
| `renovate-config.json` | Resolved Renovate preset |
| `repo-policy.json` | Desired provider/settings, preset reference, source revision and digests |

New `.github` repositories require an explicit visibility choice. Existing
organization files are shown in the diff, and unrelated files are preserved.
The installed policy is a snapshot; changing the canonical source requires
another organization deployment. Rerunning without policy changes is a no-op,
even if unrelated source commits have landed. A changed preview is rejected
before writing. Interrupted runs report errors and can be resumed after a
fresh preview; no rollback deletes a newly created repository or branch.

After merging the organization PR, `/repo:deps --install` prepares the client
to extend `github>OWNER/.github:renovate-config`, retaining local exceptions.
App installation, security flags, migration from Dependabot, and required
checks are separate adoption steps. This is not a bulk migration command.
Client exceptions are deliberate local policy; they do not change the defaults
for sibling repos. Edit organization preferences here, not in deployed copies.

## Development

```bash
python3 scripts/repo/repo-org-policy.py plan --repo OWNER/PROJECT \
  --source-dir . --create-repository public
python3 -m unittest discover -s commands/repo/tests -p 'test_org_policy.py'
```

Local-source plans are preview-only. Publishing needs canonical source on
GitHub and a newly generated plan. Never include credentials in these files.

For every effective profile, validate its `dependencies.renovate` object with
`renovate-config-validator --strict <file>` before publishing source changes.
`policies/validate-renovate.py` renders the effective profiles and invokes that
validator; CI runs it with a pinned Renovate version.
`test-release-age.mjs` also exercises that version's alert classification and
release filtering against a synthetic advisory, checking the one-day and
14-day holds plus explicit zero-delay behavior. It makes no registry/platform
requests; real lockfile resolution still needs validation in the client pilot.

References: [organization presets](https://docs.renovatebot.com/config-presets/#grouporganization-level-presets),
[security fixes](https://docs.renovatebot.com/configuration-options/#vulnerabilityalerts),
[release-age limitations](https://docs.renovatebot.com/key-concepts/minimum-release-age/).

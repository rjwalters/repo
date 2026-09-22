// Exercise the pinned Renovate implementation with a synthetic GitHub advisory.
// No platform API or registry requests are made. This intentionally uses internal
// modules: when upgrading Renovate, verify both this fixture and native behavior.
// Run: npm exec --yes --package=renovate@44.106.0 -- node policies/test-release-age.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const validator = process.env.PATH.split(path.delimiter)
  .map(directory => path.join(directory, 'renovate-config-validator'))
  .find(filename => fs.existsSync(filename));
assert.ok(validator, 'Run with Renovate on PATH, for example via npm exec --package=renovate@44.106.0');
const dist = path.dirname(fs.realpathSync(validator));
const load = name => import(pathToFileURL(path.join(dist, name + '.js')));
const [
  { getConfig }, { mergeChildConfig }, { default: platforms }, { setPlatformApi },
  { detectVulnerabilityAlerts }, { applyPackageRules }, { default: semver },
  { filterInternalChecks },
] = await Promise.all([
  load('config/defaults'), load('config/utils'), load('modules/platform/api'),
  load('modules/platform/index'), load('workers/repository/init/vulnerability'),
  load('util/package-rules/index'), load('modules/versioning/semver/index'),
  load('workers/repository/process/lookup/filter-checks'),
]);

platforms.set('github', { getVulnerabilityAlerts: async () => [{
  security_vulnerability: {
    package: { ecosystem: 'npm', name: 'fixture-security' },
    first_patched_version: { identifier: '1.0.1' }, severity: 'high',
  },
  security_advisory: {
    identifiers: [], summary: 'Local test advisory', description: 'Fixture only', references: [],
  },
}] });
setPlatformApi('github');
const preset = JSON.parse(fs.readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), 'default.json'), 'utf8',
)).dependencies.renovate;

async function configFor(name, config = preset) {
  const alerted = await detectVulnerabilityAlerts(mergeChildConfig(getConfig(), config));
  return applyPackageRules({
    ...alerted, datasource: 'npm', packageName: name, depName: name,
    currentVersion: '1.0.0', currentValue: '1.0.0', versioning: 'semver',
  }, 'test');
}

async function pending(config, hours) {
  const release = { version: '1.0.1' };
  if (hours !== null) {
    release.releaseTimestamp = new Date(Date.now() - hours * 3600000).toISOString();
  }
  return (await filterInternalChecks(config, semver, 'patch', [release])).pendingChecks;
}

const security = await configFor('fixture-security');
const routine = await configFor('fixture-routine');
assert.equal(security.isVulnerabilityAlert, true);
assert.equal(security.minimumReleaseAge, '1 day');
assert.equal(routine.minimumReleaseAge, '14 days');
assert.equal(await pending(security, 23), true);
assert.equal(await pending(security, 25), false);
assert.equal(await pending(routine, 25), true);
assert.equal(await pending(routine, 15 * 24), false);
assert.equal(await pending(security, null), true);

const immediate = await configFor('fixture-security', mergeChildConfig(preset, {
  vulnerabilityAlerts: { minimumReleaseAge: null },
}));
assert.equal(await pending(immediate, 1), false);
console.log('PASS: advisory classification, security/routine cooldowns, missing timestamps, and explicit zero-delay policy');

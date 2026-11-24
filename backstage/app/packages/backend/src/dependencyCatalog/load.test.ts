import fs from 'fs';
import path from 'path';
import { parseAllDocuments } from 'yaml';
import { Entity } from '@backstage/catalog-model';
import { buildCatalogConfig, loadCatalogData, loadTeams, ORIGIN_ANNOTATION, servicesFromEntities } from './load';
import { defaultDataPaths } from './paths';
import { DEMO_SERVICES, TEAM_A, TEAM_B } from './testFixtures';

const paths = defaultDataPaths();

const demoFile = path.join(paths.appRoot, 'catalog', 'demo-entities.yaml');
const reviewed = [demoFile];

/** The demo entities as the catalog stores them: stamped with the file location they came from. */
function demoEntities(origin = `file:${demoFile}`): Entity[] {
  return parseAllDocuments(fs.readFileSync(demoFile, 'utf8'))
    .map(d => d.toJS() as Entity)
    .filter(Boolean)
    .map(e => ({ ...e, metadata: { ...e.metadata, annotations: { ...e.metadata.annotations, [ORIGIN_ANNOTATION]: origin } } }));
}

function writeTemp(name: string, text: string): string {
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'dc-'));
  fs.writeFileSync(path.join(dir, name), text);
  return dir;
}

describe('loadTeams', () => {
  it('reads owner group, deploy repository and environments from platform/tenancy/teams', () => {
    const teams = loadTeams(paths.teams);
    expect(teams).toEqual(
      expect.arrayContaining([
        { ref: TEAM_A, deployRepo: 'team-a/deploy', environments: ['dev'] },
        { ref: TEAM_B, deployRepo: 'team-b/deploy', environments: ['dev'] },
      ]),
    );
  });
});

describe('servicesFromEntities', () => {
  it('projects the demo catalog into the services the tests use', () => {
    expect(servicesFromEntities(demoEntities(), reviewed)).toEqual(DEMO_SERVICES);
  });

  it('declares no environment outside its owning team', () => {
    const teams = loadTeams(paths.teams);
    for (const s of servicesFromEntities(demoEntities(), reviewed)) {
      const team = teams.find(t => t.ref === s.ownerRef);
      expect(team).toBeDefined();
      for (const env of s.environments) expect(team!.environments).toContain(env);
    }
  });

  it('skips components without a service type or an environments annotation', () => {
    const entities: Entity[] = [
      { apiVersion: 'backstage.io/v1alpha1', kind: 'Component', metadata: { name: 'lib' }, spec: { type: 'library', owner: 'team-a' } },
      { apiVersion: 'backstage.io/v1alpha1', kind: 'Component', metadata: { name: 'bare' }, spec: { type: 'service', owner: 'team-a' } },
    ];
    expect(servicesFromEntities(entities, reviewed)).toEqual([]);
  });
});

describe('servicesFromEntities: reviewed origins only', () => {
  it('ignores a service registered from any location other than the reviewed files', () => {
    expect(servicesFromEntities(demoEntities('url:https://github.com/someone/repo/blob/main/catalog-info.yaml'), reviewed)).toEqual([]);
    expect(servicesFromEntities(demoEntities(`file:${path.join(paths.appRoot, 'other.yaml')}`), reviewed)).toEqual([]);
  });

  it('ignores a service with no origin annotation', () => {
    const bare = demoEntities().map(e => ({ ...e, metadata: { ...e.metadata, annotations: { 'platform.example.org/environments': 'dev' } } }));
    expect(servicesFromEntities(bare, reviewed)).toEqual([]);
  });
});

describe('loadTeams: fail closed', () => {
  it('rejects two team files for the same team', () => {
    const a = fs.readFileSync(path.join(paths.teams, 'team-a.yaml'), 'utf8');
    const dir = writeTemp('team-a.yaml', a);
    fs.writeFileSync(path.join(dir, 'team-a-copy.yaml'), a.replace('team-a/deploy', 'evil/deploy'));
    expect(() => loadTeams(dir)).toThrow(/duplicate team/);
  });
});

describe('loadCatalogData: fail closed', () => {
  const original = () => fs.readFileSync(paths.fixtures, 'utf8');
  const load = (text: string) => loadCatalogData(path.join(writeTemp('fixtures.yaml', text), 'fixtures.yaml'));

  it('rejects a duplicate destination ref within a profile', () => {
    const text = original().replace(
      '      - {ref: sandbox-team-b-dev,',
      '      - {ref: sandbox-team-a-dev, kind: azure, subscriptionId: 99999999-9999-9999-9999-999999999999, resourceGroup: rg-x, approvedOwners: [group:default/team-b]}\n      - {ref: sandbox-team-b-dev,',
    );
    expect(() => load(text)).toThrow(/duplicate destination sandbox-team-a-dev/);
  });

  it('rejects a placement naming an unknown destination', () => {
    expect(() => load(original().replace('destinationRef: sandbox-team-a-dev}', 'destinationRef: nowhere}'))).toThrow(/unknown destination nowhere/);
  });

  it('rejects a placement naming an unknown offering', () => {
    expect(() => load(original().replace('offering: azure-horizondb, destinationRef: sandbox-team-a-dev', 'offering: oracle, destinationRef: sandbox-team-a-dev'))).toThrow(/unknown offering oracle/);
  });

  it('rejects a profile without placements or destinations', () => {
    expect(() => load(original().replace(/  enterprise:[\s\S]*$/, '  enterprise: {}\n'))).toThrow(/enterprise.*destinations/);
  });
});

describe('loadCatalogData', () => {
  it('labels every cost estimate as illustrative', () => {
    const data = loadCatalogData(paths.fixtures);
    expect(data.offerings.map(o => o.id)).toEqual(['azure-horizondb', 'cloudnative-pg']);
    for (const o of data.offerings) expect(o.cost?.basis).toBe('illustrative');
  });

  it('rejects a fixture whose cost is not labeled illustrative', () => {
    const tmp = path.join(fs.mkdtempSync(path.join(require('os').tmpdir(), 'dc-')), 'fixtures.yaml');
    const text = fs.readFileSync(paths.fixtures, 'utf8').replace('basis: illustrative', 'basis: quoted');
    fs.writeFileSync(tmp, text);
    expect(() => loadCatalogData(tmp)).toThrow(/illustrative/);
  });

  it('builds both placement profiles from one offering list', () => {
    const data = loadCatalogData(paths.fixtures);
    const teams = loadTeams(paths.teams);
    const sandbox = buildCatalogConfig(data, 'sandbox', teams, DEMO_SERVICES);
    const enterprise = buildCatalogConfig(data, 'enterprise', teams, DEMO_SERVICES);
    expect(sandbox.offerings).toBe(enterprise.offerings);
    expect(sandbox.destinations).not.toEqual(enterprise.destinations);
  });

  it('rejects an unknown placement profile', () => {
    const data = loadCatalogData(paths.fixtures);
    expect(() => buildCatalogConfig(data, 'nope' as any, loadTeams(paths.teams), DEMO_SERVICES)).toThrow(/profile/);
  });
});

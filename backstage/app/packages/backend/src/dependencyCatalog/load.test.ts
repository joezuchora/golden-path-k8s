import fs from 'fs';
import path from 'path';
import { parseAllDocuments } from 'yaml';
import { Entity } from '@backstage/catalog-model';
import { buildCatalogConfig, loadCatalogData, loadTeams, servicesFromEntities } from './load';
import { defaultDataPaths } from './paths';
import { DEMO_SERVICES, TEAM_A, TEAM_B } from './testFixtures';

const paths = defaultDataPaths();

function demoEntities(): Entity[] {
  const text = fs.readFileSync(path.join(paths.appRoot, 'catalog', 'demo-entities.yaml'), 'utf8');
  return parseAllDocuments(text)
    .map(d => d.toJS() as Entity)
    .filter(Boolean);
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
    expect(servicesFromEntities(demoEntities())).toEqual(DEMO_SERVICES);
  });

  it('declares no environment outside its owning team', () => {
    const teams = loadTeams(paths.teams);
    for (const s of servicesFromEntities(demoEntities())) {
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
    expect(servicesFromEntities(entities)).toEqual([]);
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

import { CatalogConfig, Destination, DependencyInput, PlacementProfileName } from './model';
import { buildCatalogConfig, loadCatalogData, loadTeams } from './load';
import { defaultDataPaths } from './paths';

export const TEAM_A = 'group:default/team-a';
export const TEAM_B = 'group:default/team-b';

/** Services as the catalog projects them from catalog/demo-entities.yaml (checked against the file in load.test.ts). */
export const DEMO_SERVICES = [
  { id: 'hello', ownerRef: TEAM_A, environments: ['dev'] },
  { id: 'inventory', ownerRef: TEAM_B, environments: ['dev'] },
];

const paths = defaultDataPaths();
const data = loadCatalogData(paths.fixtures);
const teams = loadTeams(paths.teams);

/** The real fixtures and team files, plus one cache offering to prove a database template cannot submit it. */
export function catalogConfig(profile: PlacementProfileName): CatalogConfig {
  const config = buildCatalogConfig(data, profile, teams, DEMO_SERVICES);
  return {
    ...config,
    offerings: [
      ...config.offerings,
      {
        id: 'azure-managed-redis',
        title: 'Azure Managed Redis',
        capability: 'cache',
        mode: 'managed',
        interface: 'redis',
        status: 'preview',
        operatingOwner: 'Platform team',
        availability: 'test only',
      },
    ],
  };
}

export function destinationOf(config: CatalogConfig, ref: string): Destination {
  const d = config.destinations.find(x => x.ref === ref);
  if (!d) throw new Error(`no destination ${ref}`);
  return d;
}

export function helloRequest(offering: string): DependencyInput {
  return { service: 'hello', environment: 'dev', name: 'primary-db', offering };
}

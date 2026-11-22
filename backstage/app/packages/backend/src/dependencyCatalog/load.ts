import fs from 'fs';
import path from 'path';
import { parse } from 'yaml';
import { Entity, stringifyEntityRef, parseEntityRef } from '@backstage/catalog-model';
import {
  CatalogConfig,
  Destination,
  Offering,
  Placement,
  PlacementProfileName,
  Service,
  Team,
} from './model';

/** Annotation on a service Component listing the environments it declares, comma-separated. */
export const ENVIRONMENTS_ANNOTATION = 'platform.example.org/environments';

export type CatalogData = {
  offerings: readonly Offering[];
  profiles: Record<string, { destinations: readonly Destination[]; placements: readonly Placement[] }>;
};

function fail(file: string, message: string): never {
  throw new Error(`${file}: ${message}`);
}

/** Loads the platform-owned offerings and placement profiles, refusing cost data not labeled illustrative. */
export function loadCatalogData(file: string): CatalogData {
  const doc = parse(fs.readFileSync(file, 'utf8'));
  if (doc?.version !== 1) fail(file, 'expected version: 1');
  const offerings: Offering[] = doc.offerings ?? [];
  const ids = new Set<string>();
  for (const o of offerings) {
    if (ids.has(o.id)) fail(file, `duplicate offering ${o.id}`);
    ids.add(o.id);
    if (o.cost && o.cost.basis !== 'illustrative') {
      fail(file, `offering ${o.id}: cost.basis must be "illustrative"; Milestone 1 has no qualified price data`);
    }
    if (o.status !== 'preview') fail(file, `offering ${o.id}: only status "preview" exists in Milestone 1`);
  }
  return { offerings, profiles: doc.profiles ?? {} };
}

/** Reads each team's group, deploy repository and environments from platform/tenancy/teams/<team>.yaml. */
export function loadTeams(dir: string): Team[] {
  return fs
    .readdirSync(dir)
    .filter(f => f.endsWith('.yaml'))
    .sort()
    .map(f => {
      const file = path.join(dir, f);
      const t = parse(fs.readFileSync(file, 'utf8'));
      if (typeof t?.team !== 'string' || typeof t.deployRepo !== 'string' || !Array.isArray(t.envs)) {
        fail(file, 'expected team, deployRepo and envs');
      }
      return {
        ref: stringifyEntityRef({ kind: 'group', namespace: 'default', name: t.team }),
        deployRepo: t.deployRepo,
        environments: t.envs.map(String),
      };
    });
}

/** Projects service Components (spec.type service, with the environments annotation) into catalog services. */
export function servicesFromEntities(entities: readonly Entity[]): Service[] {
  const services: Service[] = [];
  for (const e of entities) {
    const envs = e.metadata.annotations?.[ENVIRONMENTS_ANNOTATION];
    const owner = e.spec?.owner;
    if (e.kind !== 'Component' || e.spec?.type !== 'service' || !envs || typeof owner !== 'string') continue;
    if ((e.metadata.namespace ?? 'default') !== 'default') continue;
    services.push({
      id: e.metadata.name,
      ownerRef: stringifyEntityRef(parseEntityRef(owner, { defaultKind: 'group', defaultNamespace: 'default' })),
      environments: envs
        .split(',')
        .map(s => s.trim())
        .filter(Boolean),
    });
  }
  return services;
}

export function buildCatalogConfig(
  data: CatalogData,
  profile: PlacementProfileName,
  teams: readonly Team[],
  services: readonly Service[],
): CatalogConfig {
  const p = data.profiles[profile];
  if (!p) throw new Error(`unknown placement profile "${profile}"; expected one of ${Object.keys(data.profiles)}`);
  return { services, teams, offerings: data.offerings, placements: p.placements, destinations: p.destinations };
}

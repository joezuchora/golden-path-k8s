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
/** Set by the catalog: the location an entity was ingested from. */
export const ORIGIN_ANNOTATION = 'backstage.io/managed-by-origin-location';

function normalizeFile(p: string): string {
  const abs = path.resolve(p).split(path.sep).join('/');
  return process.platform === 'win32' ? abs.toLowerCase() : abs;
}

/** True when the entity came from one of the reviewed catalog files (a `file:` origin), not a runtime registration. */
export function isFromReviewedFile(e: Entity, reviewedFiles: readonly string[]): boolean {
  const origin = e.metadata.annotations?.[ORIGIN_ANNOTATION];
  if (!origin?.startsWith('file:')) return false;
  const file = normalizeFile(origin.slice('file:'.length));
  return reviewedFiles.some(r => normalizeFile(r) === file);
}

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
  const profiles = doc.profiles ?? {};
  for (const [name, profile] of Object.entries<any>(profiles)) {
    if (!Array.isArray(profile?.destinations) || !Array.isArray(profile?.placements)) {
      fail(file, `profile ${name} needs destinations and placements lists`);
    }
    const refs = new Set<string>();
    for (const d of profile.destinations as Destination[]) {
      if (refs.has(d.ref)) fail(file, `profile ${name}: duplicate destination ${d.ref}`);
      refs.add(d.ref);
    }
    for (const p of profile.placements as Placement[]) {
      if (!ids.has(p.offering)) fail(file, `profile ${name}: placement names unknown offering ${p.offering}`);
      if (!refs.has(p.destinationRef)) {
        fail(file, `profile ${name}: placement names unknown destination ${p.destinationRef}`);
      }
    }
  }
  return { offerings, profiles };
}

/** Reads each team's group, deploy repository and environments from platform/tenancy/teams/<team>.yaml. */
export function loadTeams(dir: string): Team[] {
  const teams = fs
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
  const seen = new Set<string>();
  for (const t of teams) {
    if (seen.has(t.ref)) fail(dir, `duplicate team ${t.ref}: one team file per team`);
    seen.add(t.ref);
  }
  return teams;
}

/**
 * Projects service Components (spec.type service, with the environments annotation) into catalog services. Only
 * entities ingested from the reviewed catalog files count; a Component registered at runtime is ignored.
 */
export function servicesFromEntities(entities: readonly Entity[], reviewedFiles: readonly string[]): Service[] {
  const services: Service[] = [];
  for (const e of entities) {
    if (!isFromReviewedFile(e, reviewedFiles)) continue;
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

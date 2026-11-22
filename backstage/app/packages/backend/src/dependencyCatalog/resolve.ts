import {
  Capability,
  Caller,
  CatalogConfig,
  DependencyInput,
  DependencyRequestError,
  INPUT_FIELDS,
  ResolvedRequest,
} from './model';

/** A lowercase DNS label: safe as a single path component, up to 63 characters. */
export const DNS_LABEL = /^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$/;

/** Fields the platform derives. Naming them in a request is an override attempt, reported as such. */
const PLATFORM_OWNED = /^(owner|ownerref|team|deployrepo|repo|repository|repourl|subscription|subscriptionid|resourcegroup|destination|destinationref|cluster|clusterid|workloadgroup|credentials?|token|secret|password|identity|caller)$/i;

/** Strict parse: exactly the four logical fields, each a DNS label. */
export function parseInput(raw: unknown): DependencyInput {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new DependencyRequestError(
      'invalid-input',
      'The request is not an object with service, environment, name and offering. Submit the form fields only.',
    );
  }
  const record = raw as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if ((INPUT_FIELDS as readonly string[]).includes(key)) continue;
    const why = PLATFORM_OWNED.test(key)
      ? 'is platform-owned: owner, repository, destination and credentials come from reviewed Git metadata and your sign-in'
      : 'is not part of a dependency request';
    throw new DependencyRequestError(
      'invalid-input',
      `Field "${key}" ${why}. Remove it and submit only service, environment, name and offering.`,
    );
  }
  for (const field of INPUT_FIELDS) {
    const value = record[field];
    if (typeof value !== 'string' || !DNS_LABEL.test(value)) {
      throw new DependencyRequestError(
        'invalid-input',
        `Field "${field}" is ${JSON.stringify(value)}; it must be a lowercase DNS label (a-z, 0-9, '-', at most 63 characters) because it becomes part of the request path. Use a name like "primary-db".`,
      );
    }
  }
  return {
    service: record.service as string,
    environment: record.environment as string,
    name: record.name as string,
    offering: record.offering as string,
  };
}

/**
 * Authorizes the caller and resolves the one approved destination. Ownership and the deploy repository come from
 * reviewed metadata; the caller supplies none of it. Any missing, ambiguous or unapproved placement fails closed.
 */
export function resolveRequest(
  raw: unknown,
  caller: Caller,
  config: CatalogConfig,
  capability: Capability,
): ResolvedRequest {
  const input = parseInput(raw);

  const service = config.services.find(s => s.id === input.service);
  if (!service) {
    throw new DependencyRequestError(
      'unknown-service',
      `Service "${input.service}" is not in the catalog. Pick a registered service your team owns.`,
    );
  }
  if (!caller.groupRefs.includes(service.ownerRef)) {
    throw new DependencyRequestError(
      'unauthorized',
      `You cannot request dependencies for "${input.service}": it is owned by ${service.ownerRef} and you are not a member. Ask a member of that team, or pick one of your team's services.`,
    );
  }

  const team = config.teams.find(t => t.ref === service.ownerRef);
  if (!team) {
    throw new DependencyRequestError(
      'unknown-service',
      `Service "${input.service}" is owned by ${service.ownerRef}, which has no team definition in platform/tenancy/teams. Ask the platform team to register it.`,
    );
  }
  if (!service.environments.includes(input.environment) || !team.environments.includes(input.environment)) {
    const allowed = service.environments.filter(e => team.environments.includes(e));
    throw new DependencyRequestError(
      'invalid-environment',
      `Environment "${input.environment}" is not approved for "${input.service}" (approved: ${allowed.join(', ') || 'none'}). Pick an approved environment, or add it to the service and team definitions by PR.`,
    );
  }

  const offering = config.offerings.find(o => o.id === input.offering);
  if (!offering) {
    throw new DependencyRequestError(
      'unknown-offering',
      `Offering "${input.offering}" is not in the platform catalog. Pick one of: ${config.offerings
        .filter(o => o.capability === capability)
        .map(o => o.id)
        .join(', ')}.`,
    );
  }
  if (offering.capability !== capability) {
    throw new DependencyRequestError(
      'capability-mismatch',
      `Offering "${offering.id}" is a ${offering.capability}, but this template requests a ${capability}. Use the ${offering.capability} template.`,
    );
  }

  const matches = config.placements.filter(
    p => p.owner === service.ownerRef && p.environment === input.environment && p.offering === offering.id,
  );
  if (matches.length === 0) {
    throw new DependencyRequestError(
      'no-placement',
      `No approved destination for ${service.ownerRef} in "${input.environment}" with "${offering.id}". The platform team adds placements in Git; no request file was written.`,
    );
  }
  if (matches.length > 1) {
    throw new DependencyRequestError(
      'ambiguous-placement',
      `${matches.length} destinations match ${service.ownerRef} in "${input.environment}" with "${offering.id}" (${matches
        .map(m => m.destinationRef)
        .join(', ')}). Placement must be unique; the platform team fixes it in Git. No request file was written.`,
    );
  }
  const destinationRef = matches[0].destinationRef;
  const destination = config.destinations.find(d => d.ref === destinationRef);
  if (!destination) {
    throw new DependencyRequestError(
      'unknown-destination',
      `Placement names destination "${destinationRef}", which is not defined. The platform team fixes it in Git. No request file was written.`,
    );
  }
  if (!destination.approvedOwners.includes(service.ownerRef)) {
    throw new DependencyRequestError(
      'destination-not-approved',
      `Destination "${destinationRef}" is not approved for ${service.ownerRef}. The platform team fixes the placement or grants shared access in Git. No request file was written.`,
    );
  }

  return { input, ownerRef: service.ownerRef, deployRepo: team.deployRepo, destinationRef };
}

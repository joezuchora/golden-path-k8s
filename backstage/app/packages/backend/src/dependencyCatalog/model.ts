/**
 * Dependency catalog model (D-101). A request carries only four logical fields. Owner, deploy repository and
 * destination are derived from reviewed metadata and the trusted caller, never from the request.
 */

export type Capability = 'database' | 'cache';
export type PlacementProfileName = 'sandbox' | 'enterprise';

/** The only fields a service owner supplies. */
export type DependencyInput = {
  service: string;
  environment: string;
  name: string;
  offering: string;
};
export const INPUT_FIELDS: readonly (keyof DependencyInput)[] = ['service', 'environment', 'name', 'offering'];

/** Group memberships of the signed-in user, read by the backend from the catalog. */
export type Caller = { groupRefs: readonly string[] };

export type ResolvedRequest = {
  input: DependencyInput;
  ownerRef: string;
  deployRepo: string;
  destinationRef: string;
};

export type RenderedRequest = { path: string; contents: string };

export type OfferingCost = {
  /** Only illustrative fixture data exists in Milestone 1; the loader rejects anything else. */
  basis: 'illustrative';
  inputs: readonly string[];
  allocatedMonthly?: number;
  incrementalMonthly?: number;
  currency?: string;
};

export type Offering = {
  id: string;
  title: string;
  capability: Capability;
  mode: 'managed' | 'in-cluster';
  interface: string;
  /** preview: shown and dry-runnable, not qualified for live requests. */
  status: 'preview';
  operatingOwner: string;
  availability: string;
  cost?: OfferingCost;
};

export type Destination = {
  ref: string;
  kind: 'azure' | 'in-cluster';
  /** Owner groups this destination is approved for; more than one makes it a shared destination. */
  approvedOwners: readonly string[];
  subscriptionId?: string;
  resourceGroup?: string;
  workloadGroup?: string;
};

/** Platform-owned placement, keyed on owning team, environment and offering (ADR-0014). */
export type Placement = { owner: string; environment: string; offering: string; destinationRef: string };

/** A service as the catalog projects it: owner group and declared environments. */
export type Service = { id: string; ownerRef: string; environments: readonly string[] };

/** A team as platform/tenancy/teams/<team>.yaml defines it. */
export type Team = { ref: string; deployRepo: string; environments: readonly string[] };

export type CatalogConfig = {
  services: readonly Service[];
  teams: readonly Team[];
  offerings: readonly Offering[];
  placements: readonly Placement[];
  destinations: readonly Destination[];
};

export type DependencyRequestErrorCode =
  | 'invalid-input'
  | 'unknown-service'
  | 'unauthorized'
  | 'invalid-environment'
  | 'unknown-offering'
  | 'capability-mismatch'
  | 'no-placement'
  | 'ambiguous-placement'
  | 'unknown-destination'
  | 'destination-not-approved';

const DENIALS: readonly DependencyRequestErrorCode[] = ['unauthorized', 'destination-not-approved'];

/**
 * A rejected request. The message says what failed, why, and the fix. The name is Backstage's error name for the
 * case, so the backend's error handler answers 403 for a denial and 400 for anything else.
 */
export class DependencyRequestError extends Error {
  readonly code: DependencyRequestErrorCode;

  constructor(code: DependencyRequestErrorCode, message: string) {
    super(`${message} See backstage/app/README.md#dependency-requests.`);
    this.name = DENIALS.includes(code) ? 'NotAllowedError' : 'InputError';
    this.code = code;
  }
}

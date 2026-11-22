export interface Config {
  /** Dependency catalog (D-101). */
  dependencyCatalog?: {
    /** Placement profile in the platform fixtures: sandbox (one subscription) or enterprise (simulated landing zones). */
    placementProfile?: 'sandbox' | 'enterprise';
  };
}

export interface Config {
  /** Dependency catalog (D-101). */
  dependencyCatalog?: {
    /** Placement profile in the platform fixtures: sandbox (one subscription) or enterprise (simulated landing zones). */
    placementProfile?: 'sandbox' | 'enterprise';
    /**
     * Catalog files, relative to the app root, whose service Components count as reviewed metadata. Components
     * registered from anywhere else are ignored. Default: catalog/demo-entities.yaml.
     */
    reviewedServiceFiles?: string[];
  };
}

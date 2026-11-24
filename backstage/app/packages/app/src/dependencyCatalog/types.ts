/** Offering as served by GET /api/dependency-catalog/offerings (backend dependencyCatalog/model.ts Offering). */
export type OfferingView = {
  id: string;
  title: string;
  capability: 'database' | 'cache';
  mode: 'managed' | 'in-cluster';
  interface: string;
  status: 'preview';
  operatingOwner: string;
  availability: string;
  cost?: {
    basis: 'illustrative';
    inputs: readonly string[];
    allocatedMonthly?: number;
    incrementalMonthly?: number;
    currency?: string;
  };
};

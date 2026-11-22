import path from 'path';
import { findPaths } from '@backstage/cli-common';

export type DataPaths = {
  /** backstage/app */
  appRoot: string;
  /** Platform-owned offerings and placement profiles. */
  fixtures: string;
  /** platform/tenancy/teams: the reviewed team definitions. */
  teams: string;
};

/** Paths resolved from the Backstage app root, independent of the process working directory. */
export function defaultDataPaths(): DataPaths {
  // eslint-disable-next-line no-restricted-syntax
  const appRoot = findPaths(__dirname).targetRoot;
  return {
    appRoot,
    fixtures: path.join(appRoot, 'packages', 'backend', 'src', 'dependencyCatalog', 'fixtures.yaml'),
    teams: path.resolve(appRoot, '..', '..', 'platform', 'tenancy', 'teams'),
  };
}

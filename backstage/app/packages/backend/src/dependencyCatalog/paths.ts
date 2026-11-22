import path from 'path';
import { findPaths } from '@backstage/cli-common';
import { Config } from '@backstage/config';

export type DataPaths = {
  /** backstage/app */
  appRoot: string;
  /** Platform-owned offerings and placement profiles. */
  fixtures: string;
  /** platform/tenancy/teams: the reviewed team definitions. */
  teams: string;
};

/** Paths resolved from the Backstage app root (found from the working directory, as `yarn start` and tests run it). */
export function defaultDataPaths(): DataPaths {
  // eslint-disable-next-line no-restricted-syntax
  const appRoot = findPaths(__dirname).targetRoot;
  return {
    appRoot,
    fixtures: path.join(appRoot, 'packages', 'backend', 'src', 'dependencyCatalog', 'fixtures.yaml'),
    teams: path.resolve(appRoot, '..', '..', 'platform', 'tenancy', 'teams'),
  };
}

/** The reviewed catalog files services may come from: dependencyCatalog.reviewedServiceFiles, relative to the app root. */
export function reviewedServiceFiles(config: Config, paths: DataPaths = defaultDataPaths()): string[] {
  const files = config.getOptionalStringArray('dependencyCatalog.reviewedServiceFiles') ?? ['catalog/demo-entities.yaml'];
  return files.map(f => path.resolve(paths.appRoot, f));
}

import Router from 'express-promise-router';
import { coreServices, createBackendPlugin } from '@backstage/backend-plugin-api';
import { parseEntityRef } from '@backstage/catalog-model';
import { InputError, NotFoundError } from '@backstage/errors';
import { catalogServiceRef } from '@backstage/plugin-catalog-node';
import { loadCatalogData, loadTeams, servicesFromEntities } from './load';
import { Capability } from './model';
import { defaultDataPaths } from './paths';

const CAPABILITIES: readonly Capability[] = ['database', 'cache'];

/**
 * Read-only API for the form (D-101): the approved offerings, from the same fixtures the validator loads, and a
 * service's approved environments. It authorizes nothing; dependency:renderRequest repeats every check.
 */
export const dependencyCatalogPlugin = createBackendPlugin({
  pluginId: 'dependency-catalog',
  register(env) {
    env.registerInit({
      deps: { http: coreServices.httpRouter, auth: coreServices.auth, catalog: catalogServiceRef },
      async init({ http, auth, catalog }) {
        const paths = defaultDataPaths();
        const data = loadCatalogData(paths.fixtures);
        const teams = loadTeams(paths.teams);
        const router = Router();

        router.get('/offerings', async (req, res) => {
          const capability = String(req.query.capability ?? '') as Capability;
          if (!CAPABILITIES.includes(capability)) {
            throw new InputError(`capability must be one of ${CAPABILITIES.join(', ')}`);
          }
          res.json({ offerings: data.offerings.filter(o => o.capability === capability) });
        });

        router.get('/environments', async (req, res) => {
          const ref = parseEntityRef(String(req.query.service ?? ''), { defaultKind: 'component', defaultNamespace: 'default' });
          const entity = await catalog.getEntityByRef(ref, { credentials: await auth.getOwnServiceCredentials() });
          const service = entity && servicesFromEntities([entity])[0];
          if (!service) throw new NotFoundError(`service ${req.query.service} is not in the catalog`);
          const team = teams.find(t => t.ref === service.ownerRef);
          res.json({ environments: service.environments.filter(e => team?.environments.includes(e)) });
        });

        http.use(router);
      },
    });
  },
});

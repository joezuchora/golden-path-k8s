import fs from 'fs';
import path from 'path';
import { AuthService, coreServices, createBackendModule } from '@backstage/backend-plugin-api';
import { parseEntityRef, RELATION_MEMBER_OF } from '@backstage/catalog-model';
import { catalogServiceRef, CatalogService } from '@backstage/plugin-catalog-node';
import { createTemplateAction, scaffolderActionsExtensionPoint } from '@backstage/plugin-scaffolder-node';
import { resolveSafeChildPath } from '@backstage/backend-plugin-api';
import { buildCatalogConfig, CatalogData, loadCatalogData, loadTeams, servicesFromEntities } from './load';
import { Capability, Caller, DependencyRequestError, PlacementProfileName, Team } from './model';
import { defaultDataPaths } from './paths';
import { renderRequest } from './render';
import { resolveRequest } from './resolve';

export type RenderRequestActionOptions = {
  auth: AuthService;
  catalog: CatalogService;
  data: CatalogData;
  teams: readonly Team[];
  profile: PlacementProfileName;
  /** Fixed by registration, so a database template cannot submit another kind of offering. */
  capability: Capability;
};

const unauthorized = (message: string) => new DependencyRequestError('unauthorized', message);

/** The EntityPicker submits `component:default/<name>`; only the default namespace is in scope. */
function normalizeService(request: unknown): unknown {
  if (typeof request !== 'object' || request === null || Array.isArray(request)) return request;
  const r = request as Record<string, unknown>;
  if (typeof r.service !== 'string' || !r.service.includes(':')) return request;
  let ref;
  try {
    ref = parseEntityRef(r.service);
  } catch {
    return request;
  }
  if (ref.kind.toLocaleLowerCase('en-US') !== 'component' || ref.namespace !== 'default') {
    throw new DependencyRequestError(
      'invalid-input',
      `Service "${r.service}" is not a Component in the default namespace. Pick a service from the list.`,
    );
  }
  return { ...r, service: ref.name };
}

export function createRenderRequestAction(options: RenderRequestActionOptions) {
  const { auth, catalog, data, teams, profile, capability } = options;
  return createTemplateAction({
    id: 'dependency:renderRequest',
    description:
      'Validates a dependency request against reviewed metadata and the signed-in user, then writes the request file to the workspace. Writes nothing else.',
    supportsDryRun: true,
    schema: {
      input: {
        request: z => z.unknown().describe('The form values, unmodified. Only service, environment, name and offering are accepted.'),
      },
      output: {
        path: z => z.string(),
        dryRun: z => z.boolean(),
        ownerRef: z => z.string(),
        deployRepo: z => z.string(),
        destinationRef: z => z.string(),
      },
    },
    async handler(ctx) {
      // Identity comes from the task's backend credentials, never from the form.
      const initiator = await ctx.getInitiatorCredentials();
      if (!auth.isPrincipal(initiator, 'user')) {
        throw unauthorized('Dependency requests need a signed-in user. Sign in and run the template again.');
      }
      const userRef = initiator.principal.userEntityRef;
      const credentials = await auth.getOwnServiceCredentials();
      const userEntity = await catalog.getEntityByRef(userRef, { credentials });
      if (!userEntity) {
        throw unauthorized(`Your identity ${userRef} is not in the catalog, so no team membership can be verified. Ask the platform team to register it.`);
      }
      const caller: Caller = {
        groupRefs: (userEntity.relations ?? []).filter(r => r.type === RELATION_MEMBER_OF).map(r => r.targetRef),
      };

      const { items } = await catalog.getEntities(
        { filter: { kind: 'Component', 'spec.type': 'service' } },
        { credentials },
      );
      const config = buildCatalogConfig(data, profile, teams, servicesFromEntities(items));

      const resolved = resolveRequest(normalizeService(ctx.input.request), caller, config, capability);
      const rendered = renderRequest(resolved);

      // Local-only write, confined to the task workspace.
      const target = resolveSafeChildPath(ctx.workspacePath, rendered.path);
      await fs.promises.mkdir(path.dirname(target), { recursive: true });
      await fs.promises.writeFile(target, rendered.contents, 'utf8');

      ctx.logger.info(
        `Rendered ${rendered.path} for ${resolved.ownerRef} (destination ${resolved.destinationRef}, ${
          ctx.isDryRun ? 'dry run' : 'local preview'
        }); no Git, cluster or cloud call was made`,
      );
      ctx.output('path', rendered.path);
      ctx.output('dryRun', Boolean(ctx.isDryRun));
      ctx.output('ownerRef', resolved.ownerRef);
      ctx.output('deployRepo', resolved.deployRepo);
      ctx.output('destinationRef', resolved.destinationRef);
    },
  });
}

/** Registers dependency:renderRequest on the Scaffolder. Profile: dependencyCatalog.placementProfile (default sandbox). */
export const dependencyCatalogScaffolderModule = createBackendModule({
  pluginId: 'scaffolder',
  moduleId: 'dependency-catalog',
  register(env) {
    env.registerInit({
      deps: {
        scaffolder: scaffolderActionsExtensionPoint,
        auth: coreServices.auth,
        catalog: catalogServiceRef,
        config: coreServices.rootConfig,
      },
      async init({ scaffolder, auth, catalog, config }) {
        const paths = defaultDataPaths();
        const profile = (config.getOptionalString('dependencyCatalog.placementProfile') ?? 'sandbox') as PlacementProfileName;
        const data = loadCatalogData(paths.fixtures);
        buildCatalogConfig(data, profile, [], []); // fail at startup on an unknown profile
        scaffolder.addActions(
          createRenderRequestAction({ auth, catalog, data, teams: loadTeams(paths.teams), profile, capability: 'database' }),
        );
      },
    });
  },
});

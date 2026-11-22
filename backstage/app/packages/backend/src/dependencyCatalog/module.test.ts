import fs from 'fs';
import path from 'path';
import { Entity } from '@backstage/catalog-model';
import { createMockDirectory, mockCredentials, mockServices } from '@backstage/backend-test-utils';
import { catalogServiceMock } from '@backstage/plugin-catalog-node/testUtils';
import { createMockActionContext } from '@backstage/plugin-scaffolder-node-test-utils';
import { createRenderRequestAction } from './module';
import { loadCatalogData, loadTeams } from './load';
import { defaultDataPaths } from './paths';
import { DependencyRequestError } from './model';

const paths = defaultDataPaths();
const data = loadCatalogData(paths.fixtures);
const teams = loadTeams(paths.teams);

function user(name: string, team: string): Entity {
  return {
    apiVersion: 'backstage.io/v1alpha1',
    kind: 'User',
    metadata: { name, namespace: 'default' },
    spec: { memberOf: [team] },
    relations: [{ type: 'memberOf', targetRef: `group:default/${team}` }],
  };
}

const REVIEWED = path.resolve('/reviewed/catalog/demo-entities.yaml');

function service(name: string, owner: string, origin = `file:${REVIEWED}`): Entity {
  return {
    apiVersion: 'backstage.io/v1alpha1',
    kind: 'Component',
    metadata: {
      name,
      namespace: 'default',
      annotations: { 'platform.example.org/environments': 'dev', 'backstage.io/managed-by-origin-location': origin },
    },
    spec: { type: 'service', owner, lifecycle: 'experimental' },
  };
}

const entities = [
  user('alice', 'team-a'),
  user('bob', 'team-b'),
  service('hello', 'team-a'),
  service('inventory', 'team-b'),
  service('unreviewed', 'team-a', 'url:https://github.com/someone/repo/blob/main/catalog-info.yaml'),
];

const request = { service: 'hello', environment: 'dev', name: 'primary-db', offering: 'azure-horizondb' };
const expectedPath = 'dependency-requests/dev/hello/primary-db.yaml';
const expectedBytes = 'version: 1\nservice: hello\nenvironment: dev\nname: primary-db\noffering: azure-horizondb\n';

const workspace = createMockDirectory();

function listFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(d => {
    const p = path.join(dir, d.name);
    return d.isDirectory() ? listFiles(p).map(f => `${d.name}/${f}`) : [d.name];
  });
}

function action(profile: 'sandbox' | 'enterprise' = 'sandbox') {
  return createRenderRequestAction({
    auth: mockServices.auth(),
    catalog: catalogServiceMock({ entities }),
    data,
    teams,
    profile,
    capability: 'database',
    reviewedServiceFiles: [REVIEWED],
  });
}

async function run(
  input: unknown,
  initiator = mockCredentials.user('user:default/alice'),
  opts: { profile?: 'sandbox' | 'enterprise'; isDryRun?: boolean } = {},
) {
  const output = jest.fn();
  // createMockActionContext ignores output, isDryRun and getInitiatorCredentials, so set them afterwards.
  const ctx = {
    ...createMockActionContext({ input: { request: input } as any, workspacePath: workspace.path }),
    isDryRun: opts.isDryRun ?? true,
    output,
    getInitiatorCredentials: async () => initiator,
  };
  await action(opts.profile).handler(ctx as any);
  return output;
}

beforeEach(() => workspace.clear());

describe('dependency:renderRequest', () => {
  it('writes exactly the resolved request for an authorized initiator and reports the dry-run path', async () => {
    const output = await run(request);
    expect(listFiles(workspace.path)).toEqual([expectedPath]);
    expect(fs.readFileSync(path.join(workspace.path, expectedPath), 'utf8')).toBe(expectedBytes);
    expect(output).toHaveBeenCalledWith('path', expectedPath);
    expect(output).toHaveBeenCalledWith('dryRun', true);
    expect(output).toHaveBeenCalledWith('ownerRef', 'group:default/team-a');
    expect(output).toHaveBeenCalledWith('deployRepo', 'team-a/deploy');
    expect(output).toHaveBeenCalledWith('contents', expectedBytes);
  });

  it('writes identical bytes when the same request is repeated, in either placement profile', async () => {
    await run(request);
    const first = fs.readFileSync(path.join(workspace.path, expectedPath));
    await run(request, undefined, { profile: 'enterprise' });
    expect(listFiles(workspace.path)).toEqual([expectedPath]);
    expect(fs.readFileSync(path.join(workspace.path, expectedPath)).equals(first)).toBe(true);
  });

  it('accepts the EntityPicker value for a service in the default namespace', async () => {
    await run({ ...request, service: 'component:default/hello' });
    expect(listFiles(workspace.path)).toEqual([expectedPath]);
  });

  it('denies a Team B initiator requesting Team A’s service and writes nothing', async () => {
    await expect(run(request, mockCredentials.user('user:default/bob'))).rejects.toMatchObject({ code: 'unauthorized' });
    expect(listFiles(workspace.path)).toEqual([]);
  });

  it.each([
    ['owner', 'group:default/team-b'],
    ['deployRepo', 'team-b/deploy'],
    ['subscriptionId', '22222222-2222-2222-2222-222222222222'],
    ['credentials', 'hunter2'],
  ])('rejects a form override of %s from an authorized initiator and writes nothing', async (field, value) => {
    await expect(run({ ...request, [field]: value })).rejects.toBeInstanceOf(DependencyRequestError);
    expect(listFiles(workspace.path)).toEqual([]);
  });

  it('treats a service registered outside the reviewed catalog files as unknown and writes nothing', async () => {
    await expect(run({ ...request, service: 'unreviewed' })).rejects.toMatchObject({ code: 'unknown-service' });
    expect(listFiles(workspace.path)).toEqual([]);
  });

  it('rejects a service from another namespace', async () => {
    await expect(run({ ...request, service: 'component:other/hello' })).rejects.toMatchObject({ code: 'invalid-input' });
    expect(listFiles(workspace.path)).toEqual([]);
  });

  it('rejects an initiator that is not a user', async () => {
    await expect(run(request, mockCredentials.service('plugin:catalog') as any)).rejects.toMatchObject({ code: 'unauthorized' });
    expect(listFiles(workspace.path)).toEqual([]);
  });

  it('rejects a signed-in user who is not in the catalog', async () => {
    await expect(run(request, mockCredentials.user('user:default/mallory'))).rejects.toMatchObject({ code: 'unauthorized' });
    expect(listFiles(workspace.path)).toEqual([]);
  });

  it('reports a denial as NotAllowedError and bad input as InputError, so the API answers 403 and 400', async () => {
    await expect(run(request, mockCredentials.user('user:default/bob'))).rejects.toMatchObject({ name: 'NotAllowedError' });
    await expect(run({ ...request, deployRepo: 'team-b/deploy' })).rejects.toMatchObject({ name: 'InputError' });
  });

  it('is registered with dry-run support', () => {
    expect(action().id).toBe('dependency:renderRequest');
    expect(action().supportsDryRun).toBe(true);
  });
});

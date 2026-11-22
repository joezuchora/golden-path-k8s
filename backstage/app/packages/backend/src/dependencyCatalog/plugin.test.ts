import request from 'supertest';
import { Entity } from '@backstage/catalog-model';
import { mockServices, startTestBackend } from '@backstage/backend-test-utils';
import { catalogServiceMock } from '@backstage/plugin-catalog-node/testUtils';
import path from 'path';
import { dependencyCatalogPlugin } from './plugin';
import { defaultDataPaths } from './paths';

const reviewedOrigin = `file:${path.join(defaultDataPaths().appRoot, 'catalog', 'demo-entities.yaml')}`;

const hello: Entity = {
  apiVersion: 'backstage.io/v1alpha1',
  kind: 'Component',
  metadata: {
    name: 'hello',
    namespace: 'default',
    annotations: { 'platform.example.org/environments': 'dev, staging', 'backstage.io/managed-by-origin-location': reviewedOrigin },
  },
  spec: { type: 'service', owner: 'team-a', lifecycle: 'experimental' },
};

const unreviewed: Entity = {
  ...hello,
  metadata: {
    name: 'rogue',
    namespace: 'default',
    annotations: { 'platform.example.org/environments': 'dev', 'backstage.io/managed-by-origin-location': 'url:https://github.com/x/y/blob/main/catalog-info.yaml' },
  },
};

async function server() {
  const { server: s } = await startTestBackend({
    features: [
      dependencyCatalogPlugin,
      catalogServiceMock.factory({ entities: [hello, unreviewed] }),
      mockServices.rootConfig.factory({ data: { dependencyCatalog: { placementProfile: 'sandbox' } } }),
    ],
  });
  return s;
}

describe('dependency-catalog backend plugin', () => {
  it('serves the same offering data the validator uses, for one capability', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/offerings?capability=database');
    expect(res.status).toBe(200);
    expect(res.body.offerings.map((o: { id: string }) => o.id)).toEqual(['azure-horizondb', 'cloudnative-pg']);
    expect(res.body.offerings[1]).toMatchObject({
      mode: 'in-cluster',
      cost: { basis: 'illustrative', allocatedMonthly: 60, incrementalMonthly: 140 },
    });
  });

  it('returns no offerings for a capability with none approved', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/offerings?capability=cache');
    expect(res.status).toBe(200);
    expect(res.body.offerings).toEqual([]);
  });

  it('rejects an unknown capability', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/offerings?capability=gpu');
    expect(res.status).toBe(400);
  });

  it('lists only the environments both the service and its team approve', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/environments?service=component:default/hello');
    expect(res.status).toBe(200);
    expect(res.body.environments).toEqual(['dev']);
  });

  it('answers 404 for a service registered outside the reviewed catalog files', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/environments?service=component:default/rogue');
    expect(res.status).toBe(404);
  });

  it('answers 400 for a missing service parameter', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/environments');
    expect(res.status).toBe(400);
  });

  it('answers 404 for a service that is not in the catalog', async () => {
    const res = await request(await server()).get('/api/dependency-catalog/environments?service=component:default/ghost');
    expect(res.status).toBe(404);
  });
});

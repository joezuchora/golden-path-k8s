import { resolveRequest } from './resolve';
import { DependencyRequestError } from './model';
import {
  TEAM_A,
  TEAM_B,
  catalogConfig,
  destinationOf,
  helloRequest,
} from './testFixtures';

const teamA = { groupRefs: [TEAM_A] };
const teamB = { groupRefs: [TEAM_B] };

function rejection(fn: () => unknown): DependencyRequestError {
  try {
    fn();
  } catch (e) {
    if (e instanceof DependencyRequestError) return e;
    throw e;
  }
  throw new Error('expected a DependencyRequestError, but the request resolved');
}

describe('resolveRequest: one-subscription sandbox profile', () => {
  const config = catalogConfig('sandbox');

  it('derives owner and deploy repo from reviewed metadata for an authorized caller', () => {
    const resolved = resolveRequest(helloRequest('azure-horizondb'), teamA, config, 'database');
    expect(resolved).toEqual({
      input: helloRequest('azure-horizondb'),
      ownerRef: TEAM_A,
      deployRepo: 'team-a/deploy',
      destinationRef: 'sandbox-team-a-dev',
    });
  });

  it('resolves Azure requests from two teams to the one configured subscription, in distinct resource groups', () => {
    const a = resolveRequest(helloRequest('azure-horizondb'), teamA, config, 'database');
    const b = resolveRequest(
      { service: 'inventory', environment: 'dev', name: 'primary-db', offering: 'azure-horizondb' },
      teamB,
      config,
      'database',
    );
    const da = destinationOf(config, a.destinationRef);
    const db = destinationOf(config, b.destinationRef);
    expect(da.subscriptionId).toBe(db.subscriptionId);
    expect(da.resourceGroup).not.toBe(db.resourceGroup);
  });

  it('resolves CloudNativePG to the shared workload group', () => {
    const r = resolveRequest(helloRequest('cloudnative-pg'), teamA, config, 'database');
    expect(destinationOf(config, r.destinationRef)).toMatchObject({ kind: 'in-cluster', workloadGroup: 'shared' });
  });
});

describe('resolveRequest: simulated enterprise profile', () => {
  const config = catalogConfig('enterprise');

  it('resolves the same logical Azure request to the team landing zone', () => {
    const r = resolveRequest(helloRequest('azure-horizondb'), teamA, config, 'database');
    expect(r.ownerRef).toBe(TEAM_A);
    expect(r.deployRepo).toBe('team-a/deploy');
    expect(destinationOf(config, r.destinationRef)).toMatchObject({
      kind: 'azure',
      subscriptionId: '11111111-1111-1111-1111-111111111111',
    });
  });

  it('resolves CloudNativePG to the selected workload group', () => {
    const r = resolveRequest(helloRequest('cloudnative-pg'), teamA, config, 'database');
    expect(destinationOf(config, r.destinationRef)).toMatchObject({ kind: 'in-cluster', workloadGroup: 'shared-dev' });
  });

  it('resolves the same input differently per profile while the input itself is unchanged', () => {
    const sandbox = resolveRequest(helloRequest('azure-horizondb'), teamA, catalogConfig('sandbox'), 'database');
    const enterprise = resolveRequest(helloRequest('azure-horizondb'), teamA, config, 'database');
    expect(sandbox.input).toEqual(enterprise.input);
    expect(sandbox.destinationRef).not.toBe(enterprise.destinationRef);
  });
});

describe('resolveRequest: denials', () => {
  const config = catalogConfig('sandbox');

  it('denies a caller from another team before resolving a destination', () => {
    const e = rejection(() => resolveRequest(helloRequest('azure-horizondb'), teamB, config, 'database'));
    expect(e.code).toBe('unauthorized');
    expect(e.message).toMatch(/hello/);
    expect(e.message).toMatch(/team-a/);
  });

  it('denies a caller with no group membership', () => {
    expect(rejection(() => resolveRequest(helloRequest('azure-horizondb'), { groupRefs: [] }, config, 'database')).code).toBe(
      'unauthorized',
    );
  });

  it('rejects an unknown service', () => {
    const raw = { ...helloRequest('azure-horizondb'), service: 'ghost' };
    expect(rejection(() => resolveRequest(raw, teamA, config, 'database')).code).toBe('unknown-service');
  });

  it('rejects an unknown offering', () => {
    expect(rejection(() => resolveRequest(helloRequest('oracle-rac'), teamA, config, 'database')).code).toBe(
      'unknown-offering',
    );
  });

  it('rejects an offering of a different capability than the template', () => {
    expect(rejection(() => resolveRequest(helloRequest('azure-managed-redis'), teamA, config, 'database')).code).toBe(
      'capability-mismatch',
    );
  });

  it('rejects an environment the service does not declare', () => {
    const raw = { ...helloRequest('azure-horizondb'), environment: 'prod' };
    expect(rejection(() => resolveRequest(raw, teamA, config, 'database')).code).toBe('invalid-environment');
  });

  it('rejects an environment the service declares but its team does not', () => {
    const raw = { ...helloRequest('azure-horizondb'), environment: 'staging' };
    const withStaging = {
      ...config,
      services: config.services.map(s => (s.id === 'hello' ? { ...s, environments: ['dev', 'staging'] } : s)),
    };
    expect(rejection(() => resolveRequest(raw, teamA, withStaging, 'database')).code).toBe('invalid-environment');
  });

  it('fails closed when no placement matches', () => {
    const none = { ...config, placements: config.placements.filter(p => p.offering !== 'cloudnative-pg') };
    expect(rejection(() => resolveRequest(helloRequest('cloudnative-pg'), teamA, none, 'database')).code).toBe(
      'no-placement',
    );
  });

  it('fails closed when more than one placement matches', () => {
    const dup = config.placements.find(p => p.owner === TEAM_A && p.offering === 'azure-horizondb')!;
    const ambiguous = { ...config, placements: [...config.placements, { ...dup, destinationRef: 'sandbox-team-b-dev' }] };
    expect(rejection(() => resolveRequest(helloRequest('azure-horizondb'), teamA, ambiguous, 'database')).code).toBe(
      'ambiguous-placement',
    );
  });

  it('fails closed when the placement targets a destination not approved for the owner', () => {
    const wrongOwner = {
      ...config,
      placements: config.placements.map(p =>
        p.owner === TEAM_A && p.offering === 'azure-horizondb' ? { ...p, destinationRef: 'sandbox-team-b-dev' } : p,
      ),
    };
    expect(rejection(() => resolveRequest(helloRequest('azure-horizondb'), teamA, wrongOwner, 'database')).code).toBe(
      'destination-not-approved',
    );
  });

  it('fails closed when the placement names an unknown destination', () => {
    const dangling = {
      ...config,
      placements: config.placements.map(p =>
        p.owner === TEAM_A && p.offering === 'azure-horizondb' ? { ...p, destinationRef: 'nowhere' } : p,
      ),
    };
    expect(rejection(() => resolveRequest(helloRequest('azure-horizondb'), teamA, dangling, 'database')).code).toBe(
      'unknown-destination',
    );
  });
});

describe('resolveRequest: strict input', () => {
  const config = catalogConfig('sandbox');

  it.each([
    ['deployRepo', 'team-b/deploy'],
    ['repository', 'evil/repo'],
    ['owner', TEAM_B],
    ['ownerRef', TEAM_B],
    ['subscriptionId', '22222222-2222-2222-2222-222222222222'],
    ['destinationRef', 'sandbox-team-b-dev'],
    ['credentials', 'hunter2'],
    ['token', 'ghp_x'],
    ['cluster', 'aks-prod'],
  ])('rejects a platform-owned or unknown field %s', (field, value) => {
    const e = rejection(() =>
      resolveRequest({ ...helloRequest('azure-horizondb'), [field]: value }, teamA, config, 'database'),
    );
    expect(e.code).toBe('invalid-input');
    expect(e.message).toContain(field);
  });

  it.each([
    ['service', 'Hello'],
    ['service', '../hello'],
    ['name', 'primary/db'],
    ['name', 'primary\\db'],
    ['name', '..'],
    ['name', 'primary.db'],
    ['environment', 'dev '],
    ['name', '-db'],
    ['name', 'a'.repeat(64)],
    ['name', ''],
  ])('rejects %s=%j as a path component', (field, value) => {
    const e = rejection(() =>
      resolveRequest({ ...helloRequest('azure-horizondb'), [field]: value }, teamA, config, 'database'),
    );
    expect(e.code).toBe('invalid-input');
  });

  it('accepts a 63-character name', () => {
    const r = resolveRequest({ ...helloRequest('azure-horizondb'), name: 'a'.repeat(63) }, teamA, config, 'database');
    expect(r.input.name).toHaveLength(63);
  });

  it.each([[null], ['hello'], [[]], [{ service: 'hello' }], [{ ...{ service: 'hello', environment: 'dev', name: 'db' }, offering: 3 }]])(
    'rejects a malformed request %j',
    raw => {
      expect(rejection(() => resolveRequest(raw, teamA, config, 'database')).code).toBe('invalid-input');
    },
  );
});

import { parse } from 'yaml';
import { renderRequest } from './render';
import { resolveRequest } from './resolve';
import { TEAM_A, catalogConfig, helloRequest } from './testFixtures';

const teamA = { groupRefs: [TEAM_A] };

describe.each(['azure-horizondb', 'cloudnative-pg'])('renderRequest: hello/dev/primary-db with %s', offering => {
  it.each(['sandbox', 'enterprise'] as const)('renders the design file at the exact path (%s profile)', profile => {
    const rendered = renderRequest(resolveRequest(helloRequest(offering), teamA, catalogConfig(profile), 'database'));
    expect(rendered.path).toBe('dependency-requests/dev/hello/primary-db.yaml');
    expect(parse(rendered.contents)).toEqual({
      version: 1,
      service: 'hello',
      environment: 'dev',
      name: 'primary-db',
      offering,
    });
  });

  it('emits the five fields in stable order with no platform coordinates', () => {
    const rendered = renderRequest(resolveRequest(helloRequest(offering), teamA, catalogConfig('sandbox'), 'database'));
    expect(rendered.contents).toBe(
      `version: 1\nservice: hello\nenvironment: dev\nname: primary-db\noffering: ${offering}\n`,
    );
    expect(rendered.contents).not.toMatch(/subscription|resourceGroup|destination|team-a|deploy|workloadGroup/);
  });

  it('produces identical bytes for repeated requests and across placement profiles', () => {
    const once = renderRequest(resolveRequest(helloRequest(offering), teamA, catalogConfig('sandbox'), 'database'));
    const again = renderRequest(resolveRequest(helloRequest(offering), teamA, catalogConfig('sandbox'), 'database'));
    const enterprise = renderRequest(resolveRequest(helloRequest(offering), teamA, catalogConfig('enterprise'), 'database'));
    expect(again).toEqual(once);
    expect(enterprise).toEqual(once);
  });
});

describe('renderRequest: defence in depth', () => {
  it('refuses to render a path component that is not a DNS label, even if handed one directly', () => {
    const resolved = resolveRequest(helloRequest('azure-horizondb'), teamA, catalogConfig('sandbox'), 'database');
    expect(() => renderRequest({ ...resolved, input: { ...resolved.input, name: '../../etc' } })).toThrow(/name/);
  });
});

import guestProvider from '@backstage/plugin-auth-backend-module-guest-provider';
import { demoOnlyFeatures } from './features';

describe('demoOnlyFeatures', () => {
  it('registers the guest sign-in only under NODE_ENV=development', () => {
    expect(demoOnlyFeatures('development')).toEqual([guestProvider]);
    for (const env of ['production', 'test', undefined]) expect(demoOnlyFeatures(env)).toEqual([]);
  });
});

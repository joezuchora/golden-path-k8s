import guestProvider from '@backstage/plugin-auth-backend-module-guest-provider';

/**
 * Backend features that exist only for the local demo (D-101). The guest sign-in is registered only under
 * NODE_ENV=development, so a deployment never loads it, whatever its merged config contains.
 */
export function demoOnlyFeatures(nodeEnv: string | undefined) {
  return nodeEnv === 'development' ? [guestProvider] : [];
}

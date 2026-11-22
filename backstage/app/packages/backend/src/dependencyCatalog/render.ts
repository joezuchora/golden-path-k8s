import { isSafeLabel } from './resolve';
import { INPUT_FIELDS, RenderedRequest, ResolvedRequest } from './model';

/**
 * Renders the inert request file under dependency-requests/<env>/<service>/<name>.yaml, outside the xrs/<env>/ Argo CD
 * path. Only the logical request is written: owner, repository and destination stay out of the file. The output is a
 * pure function of the four fields, so retries produce identical bytes.
 */
export function renderRequest(resolved: ResolvedRequest): RenderedRequest {
  const { input } = resolved;
  for (const field of INPUT_FIELDS) {
    if (!isSafeLabel(input[field])) throw new Error(`refusing to render: ${field} is not a YAML-safe DNS label`);
  }
  return {
    path: `dependency-requests/${input.environment}/${input.service}/${input.name}.yaml`,
    contents: [
      'version: 1',
      `service: ${input.service}`,
      `environment: ${input.environment}`,
      `name: ${input.name}`,
      `offering: ${input.offering}`,
      '',
    ].join('\n'),
  };
}

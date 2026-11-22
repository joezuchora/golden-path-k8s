import { useEffect, useState } from 'react';
import { Box, FormControlLabel, FormHelperText, Radio, RadioGroup, Typography } from '@material-ui/core';
import { discoveryApiRef, fetchApiRef, useApi } from '@backstage/core-plugin-api';
import { FieldExtensionComponentProps } from '@backstage/plugin-scaffolder-react';

/**
 * Scaffolder field: ui:field DependencyEnvironmentPicker. Lists the environments the selected service declares and
 * its team approves (GET /api/dependency-catalog/environments). The backend action repeats this check.
 */
export function EnvironmentPicker(props: FieldExtensionComponentProps<string>) {
  const { onChange, formData, formContext, schema, rawErrors, required } = props;
  const service: string | undefined = formContext?.formData?.service;
  const discovery = useApi(discoveryApiRef);
  const { fetch } = useApi(fetchApiRef);
  const [environments, setEnvironments] = useState<string[]>();
  const [error, setError] = useState<string>();

  useEffect(() => {
    setEnvironments(undefined);
    setError(undefined);
    if (!service) return undefined;
    let cancelled = false;
    (async () => {
      const base = await discovery.getBaseUrl('dependency-catalog');
      const res = await fetch(`${base}/environments?service=${encodeURIComponent(service)}`);
      if (!res.ok) throw new Error(`environments request failed: ${res.status}`);
      const body = await res.json();
      if (!cancelled) setEnvironments(body.environments);
    })().catch(e => !cancelled && setError(String(e)));
    return () => {
      cancelled = true;
    };
  }, [discovery, fetch, service]);

  return (
    <Box mb={2}>
      <Typography variant="subtitle1">
        {schema.title ?? 'Environment'}
        {required ? ' *' : ''}
      </Typography>
      {!service && <Typography variant="body2">Select a service first.</Typography>}
      {error && <FormHelperText error>Could not load the service's environments: {error}</FormHelperText>}
      {environments && environments.length === 0 && (
        <Typography variant="body2">This service has no approved environments.</Typography>
      )}
      {environments && environments.length > 0 && (
        <RadioGroup row value={formData ?? ''} onChange={e => onChange(e.target.value)}>
          {environments.map(env => (
            <FormControlLabel key={env} value={env} control={<Radio inputProps={{ 'aria-label': env }} />} label={env} />
          ))}
        </RadioGroup>
      )}
      {rawErrors?.length ? <FormHelperText error>{rawErrors.join(' ')}</FormHelperText> : null}
    </Box>
  );
}

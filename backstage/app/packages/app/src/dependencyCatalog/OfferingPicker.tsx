import { useEffect, useState } from 'react';
import { Box, Card, CardActionArea, CardContent, Chip, FormHelperText, Grid, Typography } from '@material-ui/core';
import { discoveryApiRef, fetchApiRef, useApi } from '@backstage/core-plugin-api';
import { FieldExtensionComponentProps } from '@backstage/plugin-scaffolder-react';
import { OfferingView } from './types';

function money(currency: string | undefined, amount: number) {
  return `${currency ?? 'USD'} ${amount}/month`;
}

function CostSection({ offering }: { offering: OfferingView }) {
  const { cost } = offering;
  if (!cost) {
    return <Typography variant="body2">No cost estimate is available for this option yet.</Typography>;
  }
  const hasMonthly = cost.allocatedMonthly !== undefined || cost.incrementalMonthly !== undefined;
  return (
    <Box>
      <Typography variant="body2" color="textSecondary">
        <strong>Illustrative estimate, not a quote.</strong> Fixture data for this preview.
      </Typography>
      {offering.mode === 'in-cluster' && cost.allocatedMonthly !== undefined && (
        <Typography variant="body2">{`Allocated capacity: ${money(cost.currency, cost.allocatedMonthly)}`}</Typography>
      )}
      {offering.mode === 'in-cluster' && cost.incrementalMonthly !== undefined && (
        <Typography variant="body2">
          {`Added node capacity, if needed: ${money(cost.currency, cost.incrementalMonthly)}`}
        </Typography>
      )}
      {offering.mode === 'managed' && cost.allocatedMonthly !== undefined && (
        <Typography variant="body2">{`Service estimate: ${money(cost.currency, cost.allocatedMonthly)}`}</Typography>
      )}
      {!hasMonthly && <Typography variant="body2">Monthly estimate unavailable: no regional rate in this preview.</Typography>}
      <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>
        {cost.inputs.map(input => (
          <li key={input}>
            <Typography variant="body2">{input}</Typography>
          </li>
        ))}
      </ul>
    </Box>
  );
}

export type OfferingCardsProps = {
  offerings: readonly OfferingView[];
  selected?: string;
  onSelect: (id: string) => void;
};

/** Side-by-side option cards: operating owner, availability and labeled cost assumptions for each choice. */
export function OfferingCards({ offerings, selected, onSelect }: OfferingCardsProps) {
  return (
    <Grid container spacing={2} role="radiogroup">
      {offerings.map(o => (
        <Grid item xs={12} md={6} key={o.id}>
          <Card variant="outlined" style={selected === o.id ? { borderColor: '#1976d2', borderWidth: 2 } : undefined}>
            <CardActionArea role="radio" aria-checked={selected === o.id} aria-label={o.title} onClick={() => onSelect(o.id)}>
              <CardContent>
                <Box display="flex" justifyContent="space-between" alignItems="center">
                  <Typography variant="h6">{o.title}</Typography>
                  <Chip size="small" label="Preview: dry run only" />
                </Box>
                <Typography variant="body2" color="textSecondary" gutterBottom>
                  {o.mode === 'managed' ? 'Managed service' : 'In-cluster on AKS'} · {o.interface}
                </Typography>
                <Typography variant="body2">
                  <strong>Operated by:</strong> {o.operatingOwner}
                </Typography>
                <Typography variant="body2" gutterBottom>
                  <strong>Availability:</strong> {o.availability?.trim() || 'Availability estimate unavailable.'}
                </Typography>
                <CostSection offering={o} />
              </CardContent>
            </CardActionArea>
          </Card>
        </Grid>
      ))}
    </Grid>
  );
}

/** Scaffolder field: ui:field OfferingPicker, ui:options.capability database|cache. Value is the offering id. */
export function OfferingPicker(props: FieldExtensionComponentProps<string, { capability?: string }>) {
  const { onChange, formData, uiSchema, schema, rawErrors, required } = props;
  const capability = uiSchema?.['ui:options']?.capability ?? 'database';
  const discovery = useApi(discoveryApiRef);
  const { fetch } = useApi(fetchApiRef);
  const [offerings, setOfferings] = useState<OfferingView[]>();
  const [error, setError] = useState<string>();

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const base = await discovery.getBaseUrl('dependency-catalog');
      const res = await fetch(`${base}/offerings?capability=${encodeURIComponent(capability)}`);
      if (!res.ok) throw new Error(`offerings request failed: ${res.status}`);
      const body = await res.json();
      if (!cancelled) setOfferings(body.offerings);
    })().catch(e => !cancelled && setError(String(e)));
    return () => {
      cancelled = true;
    };
  }, [discovery, fetch, capability]);

  return (
    <Box mb={2}>
      <Typography variant="subtitle1">
        {schema.title ?? 'Offering'}
        {required ? ' *' : ''}
      </Typography>
      <Typography variant="body2" color="textSecondary" gutterBottom>
        Both options are designed to the same availability target; neither is qualified on this platform yet. The
        platform resolves where it runs from approved placement; you only choose the offering.
      </Typography>
      {error && <FormHelperText error>Could not load the approved offerings: {error}</FormHelperText>}
      {!error && !offerings && <Typography variant="body2">Loading approved offerings…</Typography>}
      {offerings && offerings.length === 0 && <Typography variant="body2">No approved offerings for {capability}.</Typography>}
      {offerings && offerings.length > 0 && <OfferingCards offerings={offerings} selected={formData} onSelect={onChange} />}
      {rawErrors?.length ? <FormHelperText error>{rawErrors.join(' ')}</FormHelperText> : null}
    </Box>
  );
}

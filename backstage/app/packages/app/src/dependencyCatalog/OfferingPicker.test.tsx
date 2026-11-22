import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { TestApiProvider } from '@backstage/frontend-test-utils';
import { discoveryApiRef, fetchApiRef } from '@backstage/core-plugin-api';
import { OfferingCards, OfferingPicker } from './OfferingPicker';
import { OfferingView } from './types';

const horizon: OfferingView = {
  id: 'azure-horizondb',
  title: 'Azure HorizonDB',
  capability: 'database',
  mode: 'managed',
  interface: 'postgresql',
  status: 'preview',
  operatingOwner: 'Platform team (Azure-managed service)',
  availability: 'Zone-redundant target. Not yet qualified on this platform.',
  cost: {
    basis: 'illustrative',
    inputs: ['Region: the destination region (regional rate unavailable in this preview)', 'Sizing: 2 vCores'],
  },
};

const cnpg: OfferingView = {
  id: 'cloudnative-pg',
  title: 'PostgreSQL on AKS (CloudNativePG)',
  capability: 'database',
  mode: 'in-cluster',
  interface: 'postgresql',
  status: 'preview',
  operatingOwner: 'Platform team (operates the operator on the workload AKS)',
  availability: 'Zone-redundant target (one primary, one standby).',
  cost: {
    basis: 'illustrative',
    currency: 'USD',
    allocatedMonthly: 60,
    incrementalMonthly: 140,
    inputs: ['Allocated: 2 x (1 vCPU, 4 GiB)', 'Incremental: one added node'],
  },
};

const noCost: OfferingView = { ...cnpg, id: 'no-cost', title: 'Unpriced option', cost: undefined };

function card(title: string) {
  return within(screen.getByRole('radio', { name: new RegExp(title) }));
}

describe('OfferingCards', () => {
  it('shows each option’s operating owner, availability and preview status', () => {
    render(<OfferingCards offerings={[horizon, cnpg]} onSelect={() => {}} />);
    expect(card('Azure HorizonDB').getByText(/Platform team \(Azure-managed service\)/)).toBeInTheDocument();
    expect(card('Azure HorizonDB').getByText(/Zone-redundant target/)).toBeInTheDocument();
    expect(card('CloudNativePG').getByText(/Operated by/)).toBeInTheDocument();
    expect(card('CloudNativePG').getByText(/Preview: dry run only/)).toBeInTheDocument();
  });

  it('labels sample pricing as illustrative, never as a live rate', () => {
    render(<OfferingCards offerings={[horizon, cnpg]} onSelect={() => {}} />);
    for (const title of ['Azure HorizonDB', 'CloudNativePG']) {
      expect(card(title).getByText(/Illustrative estimate, not a quote/)).toBeInTheDocument();
    }
  });

  it('shows region and sizing inputs and an unavailable rate for the managed option', () => {
    render(<OfferingCards offerings={[horizon]} onSelect={() => {}} />);
    expect(card('Azure HorizonDB').getByText(/Sizing: 2 vCores/)).toBeInTheDocument();
    expect(card('Azure HorizonDB').getByText(/Monthly estimate unavailable/)).toBeInTheDocument();
  });

  it('separates allocated capacity from added node spend for the in-cluster option', () => {
    render(<OfferingCards offerings={[cnpg]} onSelect={() => {}} />);
    expect(card('CloudNativePG').getByText('Allocated capacity: USD 60/month')).toBeInTheDocument();
    expect(card('CloudNativePG').getByText('Added node capacity, if needed: USD 140/month')).toBeInTheDocument();
  });

  it('says when an offering has no cost data at all', () => {
    render(<OfferingCards offerings={[noCost]} onSelect={() => {}} />);
    expect(card('Unpriced option').getByText(/No cost estimate is available/)).toBeInTheDocument();
  });

  it('says when availability data is missing instead of showing a blank', () => {
    render(<OfferingCards offerings={[{ ...cnpg, title: 'No availability', availability: '' }]} onSelect={() => {}} />);
    expect(card('No availability').getByText(/Availability estimate unavailable/)).toBeInTheDocument();
  });

  it('selects an option by id', () => {
    const onSelect = jest.fn();
    render(<OfferingCards offerings={[horizon, cnpg]} selected="azure-horizondb" onSelect={onSelect} />);
    expect(screen.getByRole('radio', { name: /Azure HorizonDB/ })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('radio', { name: /CloudNativePG/ }));
    expect(onSelect).toHaveBeenCalledWith('cloudnative-pg');
  });
});

describe('OfferingPicker field', () => {
  it('loads the approved offerings for its capability from the backend and reports the selection', async () => {
    const fetch = jest.fn(async (url: string) => ({
      ok: true,
      json: async () => ({ offerings: url.includes('capability=database') ? [horizon, cnpg] : [] }),
    }));
    const onChange = jest.fn();
    render(
      <TestApiProvider
        apis={[
          [fetchApiRef, { fetch } as any],
          [discoveryApiRef, { getBaseUrl: async (id: string) => `http://localhost:7007/api/${id}` }],
        ]}
      >
        <OfferingPicker
          {...({
            onChange,
            formData: undefined,
            uiSchema: { 'ui:options': { capability: 'database' } },
            schema: { title: 'Offering' },
            rawErrors: [],
            required: true,
          } as any)}
        />
      </TestApiProvider>,
    );
    await waitFor(() => expect(screen.getAllByRole('radio')).toHaveLength(2));
    expect(screen.queryByText(/meet the same availability target/)).not.toBeInTheDocument();
    expect(screen.getByText(/neither is qualified on this platform yet/)).toBeInTheDocument();
    expect(fetch).toHaveBeenCalledWith('http://localhost:7007/api/dependency-catalog/offerings?capability=database');
    fireEvent.click(screen.getByRole('radio', { name: /Azure HorizonDB/ }));
    expect(onChange).toHaveBeenCalledWith('azure-horizondb');
  });
});

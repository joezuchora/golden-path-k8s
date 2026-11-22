import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { TestApiProvider } from '@backstage/frontend-test-utils';
import { discoveryApiRef, fetchApiRef } from '@backstage/core-plugin-api';
import { EnvironmentPicker } from './EnvironmentPicker';

function renderPicker(service: string | undefined, onChange = jest.fn()) {
  const fetch = jest.fn(async (_url: string) => ({ ok: true, json: async () => ({ environments: ['dev'] }) }));
  render(
    <TestApiProvider
      apis={[
        [fetchApiRef, { fetch } as any],
        [discoveryApiRef, { getBaseUrl: async (id: string) => `http://localhost:7007/api/${id}` }],
      ]}
    >
      <EnvironmentPicker
        {...({
          onChange,
          formData: undefined,
          formContext: { formData: { service } },
          uiSchema: {},
          schema: { title: 'Environment' },
          rawErrors: [],
          required: true,
        } as any)}
      />
    </TestApiProvider>,
  );
  return { fetch, onChange };
}

describe('EnvironmentPicker', () => {
  it('offers only the environments the backend approves for the selected service', async () => {
    const { fetch, onChange } = renderPicker('component:default/hello');
    await waitFor(() => expect(screen.getByRole('radio', { name: 'dev' })).toBeInTheDocument());
    expect(fetch).toHaveBeenCalledWith(
      'http://localhost:7007/api/dependency-catalog/environments?service=component%3Adefault%2Fhello',
    );
    expect(screen.getAllByRole('radio')).toHaveLength(1);
    fireEvent.click(screen.getByRole('radio', { name: 'dev' }));
    expect(onChange).toHaveBeenCalledWith('dev');
  });

  it('asks for a service first and fetches nothing', () => {
    const { fetch } = renderPicker(undefined);
    expect(screen.getByText(/Select a service first/)).toBeInTheDocument();
    expect(fetch).not.toHaveBeenCalled();
  });
});

import { createFrontendModule } from '@backstage/frontend-plugin-api';
import { createFormField, FormFieldBlueprint } from '@backstage/plugin-scaffolder-react/alpha';

/** Dependency catalog form fields (D-101), registered on the Scaffolder. */
const offeringPickerField = FormFieldBlueprint.make({
  name: 'offering-picker',
  params: {
    field: () =>
      import('./OfferingPicker').then(m => createFormField({ name: 'OfferingPicker', component: m.OfferingPicker })),
  },
});

const environmentPickerField = FormFieldBlueprint.make({
  name: 'dependency-environment-picker',
  params: {
    field: () =>
      import('./EnvironmentPicker').then(m =>
        createFormField({ name: 'DependencyEnvironmentPicker', component: m.EnvironmentPicker }),
      ),
  },
});

export const dependencyCatalogModule = createFrontendModule({
  pluginId: 'scaffolder',
  extensions: [offeringPickerField, environmentPickerField],
});

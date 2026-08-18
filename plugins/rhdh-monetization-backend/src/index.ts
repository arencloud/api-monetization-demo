import { createBackendFeatureLoader } from '@backstage/backend-plugin-api';
import { apiMonetizationPlugin } from './plugin';
import { apiMonetizationRbacModule } from './rbac-module';

export * from './permissions';
export { apiMonetizationPlugin } from './plugin';
export { apiMonetizationRbacModule } from './rbac-module';

export default createBackendFeatureLoader({
  loader() {
    return [apiMonetizationPlugin, apiMonetizationRbacModule];
  },
});

import { pluginIdProviderExtensionPoint } from '@backstage-community/plugin-rbac-node';
import { createBackendModule } from '@backstage/backend-plugin-api';

export const apiMonetizationRbacModule = createBackendModule({
  pluginId: 'permission',
  moduleId: 'api-monetization-rbac-provider',
  register(env) {
    env.registerInit({
      deps: { pluginIdProvider: pluginIdProviderExtensionPoint },
      async init({ pluginIdProvider }) {
        pluginIdProvider.addPluginIdProvider({
          getPluginIds: () => ['api-monetization'],
        });
      },
    });
  },
});

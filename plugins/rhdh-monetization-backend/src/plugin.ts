import { coreServices, createBackendPlugin } from '@backstage/backend-plugin-api';
import { createPermissionIntegrationRouter } from '@backstage/plugin-permission-node';
import { apiMonetizationPermissions } from './permissions';
import { createRouter } from './router';

export const apiMonetizationPlugin = createBackendPlugin({
  pluginId: 'api-monetization',
  register(env) {
    env.registerInit({
      deps: {
        config: coreServices.rootConfig,
        httpAuth: coreServices.httpAuth,
        httpRouter: coreServices.httpRouter,
        permissions: coreServices.permissions,
      },
      async init({ config, httpAuth, httpRouter, permissions }) {
        httpRouter.addAuthPolicy({
          path: '/devspaces/open',
          allow: 'unauthenticated',
        });
        httpRouter.use(createPermissionIntegrationRouter({
          permissions: apiMonetizationPermissions,
        }));
        httpRouter.use(await createRouter({ config, httpAuth, permissions }));
      },
    });
  },
});

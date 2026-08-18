import { createPlugin, createRouteRef, createRoutableExtension } from '@backstage/core-plugin-api';

const rootRouteRef = createRouteRef({
  id: 'api-monetization-policy-catalog',
});

export const policyCatalogPlugin = createPlugin({
  id: 'api-monetization-policy-catalog',
  routes: { root: rootRouteRef },
});

export const ApiProductsPage = policyCatalogPlugin.provide(
  createRoutableExtension({
    name: 'ApiProductsPage',
    component: () =>
      import('./components/ApiProductsPage').then(module => module.ApiProductsPage),
    mountPoint: rootRouteRef,
  }),
);

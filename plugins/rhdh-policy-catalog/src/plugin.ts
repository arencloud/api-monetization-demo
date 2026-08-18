import { createPlugin, createRouteRef, createRoutableExtension } from '@backstage/core-plugin-api';

const rootRouteRef = createRouteRef({
  id: 'api-monetization-policy-catalog',
});

const monetizationRouteRef = createRouteRef({
  id: 'api-monetization-overview',
});

export const policyCatalogPlugin = createPlugin({
  id: 'api-monetization-policy-catalog',
  routes: { root: rootRouteRef, monetization: monetizationRouteRef },
});

export const ApiProductsPage = policyCatalogPlugin.provide(
  createRoutableExtension({
    name: 'ApiProductsPage',
    component: () =>
      import('./components/ApiProductsPage').then(module => module.ApiProductsPage),
    mountPoint: rootRouteRef,
  }),
);

export const MonetizationPage = policyCatalogPlugin.provide(
  createRoutableExtension({
    name: 'MonetizationPage',
    component: () =>
      import('./components/MonetizationPage').then(module => module.MonetizationPage),
    mountPoint: monetizationRouteRef,
  }),
);

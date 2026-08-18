import {
  configApiRef,
  createApiFactory,
  createApiRef,
  discoveryApiRef,
  OAuthApi,
  oauthRequestApiRef,
} from '@backstage/core-plugin-api';
import { OAuth2 } from '@backstage/core-app-api';

/**
 * RHDH supports the generic OIDC backend provider for sign-in, but does not
 * register a matching frontend API factory. Dynamic pages that need the
 * provider access token must register the factory explicitly.
 */
export const oidcAuthApiRef = createApiRef<OAuthApi>({ id: 'auth.oidc' });

export const oidcAuthApiFactory = createApiFactory({
  api: oidcAuthApiRef,
  deps: {
    configApi: configApiRef,
    discoveryApi: discoveryApiRef,
    oauthRequestApi: oauthRequestApiRef,
  },
  factory: ({ configApi, discoveryApi, oauthRequestApi }) =>
    OAuth2.create({
      configApi,
      discoveryApi,
      oauthRequestApi,
      environment: configApi.getOptionalString('auth.environment') ?? 'production',
      provider: {
        id: 'oidc',
        title: 'Keycloak',
        icon: () => null,
      },
      defaultScopes: ['openid', 'profile', 'email'],
    }),
});

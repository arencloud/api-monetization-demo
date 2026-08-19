import { inferCommercialProduct } from './MonetizedApisPage';

const entity = (name: string, apiProduct?: string) => ({
  apiVersion: 'backstage.io/v1alpha1',
  kind: 'API',
  metadata: {
    name,
    annotations: apiProduct ? {'kuadrant.io/apiproduct': apiProduct} : undefined,
  },
});

describe('commercial product inference', () => {
  it('maps both Kuadrant authentication products to one commercial product', () => {
    expect(inferCommercialProduct(entity('time-api', 'time-api'))).toBe('time');
    expect(inferCommercialProduct(entity('time-api-jwt', 'time-api-jwt'))).toBe('time');
    expect(inferCommercialProduct(entity('weather-api-api', 'weather-api-api'))).toBe('weather-api');
  });

  it('retains built-in catalog compatibility', () => {
    expect(inferCommercialProduct(entity('inventory-api'))).toBe('inventory');
  });
});

import { InputError } from '@backstage/errors';
import { buildDevSpacesFactoryUrl } from './router';

describe('OpenShift Dev Spaces factory URL', () => {
  it('builds a portable factory URL for one generated GitHub repository', () => {
    expect(buildDevSpacesFactoryUrl(
      'https://devspaces.apps.example.com/',
      'arencloud',
      'time-api',
    )).toBe(
      'https://devspaces.apps.example.com#https://github.com/arencloud/time-api',
    );
  });

  it.each([
    ['arencloud/path', 'time-api'],
    ['arencloud', '../time-api'],
    ['arencloud', 'time-api?redirect=https://example.com'],
    ['', 'time-api'],
  ])('rejects unsafe repository coordinates', (owner, repository) => {
    expect(() => buildDevSpacesFactoryUrl(
      'https://devspaces.apps.example.com',
      owner,
      repository,
    )).toThrow(InputError);
  });

  it.each([
    'http://devspaces.apps.example.com',
    'https://user:password@devspaces.apps.example.com',
    'https://devspaces.apps.example.com?target=other',
    'not-a-url',
  ])('rejects an unsafe Dev Spaces base URL', baseUrl => {
    expect(() => buildDevSpacesFactoryUrl(
      baseUrl,
      'arencloud',
      'time-api',
    )).toThrow(InputError);
  });
});

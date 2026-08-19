import { devSpacesUrlForProject } from '../devspaces';

describe('Dev Spaces entity action', () => {
  it('creates the RHDH redirect for a valid GitHub project slug', () => {
    expect(devSpacesUrlForProject('arencloud/time')).toBe(
      '/api/api-monetization/devspaces/open?owner=arencloud&repo=time',
    );
  });

  it.each([
    undefined,
    '',
    'arencloud',
    'arencloud/time/other',
    'arencloud/../time',
    'arencloud/time?redirect=other',
  ])('rejects a missing or unsafe project slug', projectSlug => {
    expect(devSpacesUrlForProject(projectSlug)).toBeUndefined();
  });
});

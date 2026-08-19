const githubProjectSlug = /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})$/;

export const githubCoordinates = (projectSlug: unknown): [string, string] | undefined => {
  if (typeof projectSlug !== 'string' || !githubProjectSlug.test(projectSlug)) {
    return undefined;
  }
  const [owner, repo] = projectSlug.split('/');
  return [owner, repo];
};

export const devSpacesUrlForProject = (projectSlug: unknown): string | undefined => {
  const coordinates = githubCoordinates(projectSlug);
  if (!coordinates) return undefined;
  const [owner, repo] = coordinates;
  return `/api/api-monetization/devspaces/open?owner=${encodeURIComponent(owner)}&repo=${encodeURIComponent(repo)}`;
};

export const publicationPathForProject = (projectSlug: unknown): string | undefined => {
  const coordinates = githubCoordinates(projectSlug);
  if (!coordinates) return undefined;
  const [owner, repo] = coordinates;
  return `/publications/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`;
};

const githubProjectSlug = /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})$/;

export const devSpacesUrlForProject = (projectSlug: unknown): string | undefined => {
  if (typeof projectSlug !== 'string' || !githubProjectSlug.test(projectSlug)) {
    return undefined;
  }
  const [owner, repo] = projectSlug.split('/');
  return `/api/api-monetization/devspaces/open?owner=${encodeURIComponent(owner)}&repo=${encodeURIComponent(repo)}`;
};

import { useEntity } from '@backstage/plugin-catalog-react';
import { discoveryApiRef, fetchApiRef, useApi } from '@backstage/core-plugin-api';
import { Box, Button, Card, CardActions, CardContent, Chip, Typography } from '@material-ui/core';
import LaunchIcon from '@material-ui/icons/Launch';
import PublishIcon from '@material-ui/icons/Publish';
import React, { useEffect, useState } from 'react';
import useAsync from 'react-use/lib/useAsync';
import { devSpacesUrlForProject, publicationPathForProject } from '../devspaces';

interface PublicationStatus {
  phase: 'not-published' | 'deploying' | 'ready' | 'failed';
  syncStatus?: string;
  healthStatus?: string;
  message?: string;
  apiKeyEndpoint?: string;
  jwtEndpoint?: string;
}

export const EntityDevSpacesCard = () => {
  const { entity } = useEntity();
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);
  const [refresh, setRefresh] = useState(0);
  const [publishing, setPublishing] = useState(false);
  const [actionError, setActionError] = useState<string>();
  const projectSlug = entity.metadata.annotations?.['github.com/project-slug'];
  const devSpacesUrl = devSpacesUrlForProject(projectSlug);
  const publicationPath = publicationPathForProject(projectSlug);

  const publication = useAsync(async () => {
    void refresh;
    if (!publicationPath) return undefined;
    const baseUrl = await discoveryApi.getBaseUrl('api-monetization');
    const response = await fetchApi.fetch(`${baseUrl}${publicationPath}`);
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error?.message || body.error || `Publication status failed: HTTP ${response.status}`);
    return body as PublicationStatus;
  }, [discoveryApi, fetchApi, publicationPath, refresh]);

  useEffect(() => {
    if (publication.value?.phase !== 'deploying') return undefined;
    const timer = window.setTimeout(() => setRefresh(value => value + 1), 5000);
    return () => window.clearTimeout(timer);
  }, [publication.value?.phase, refresh]);

  const publish = async () => {
    if (!publicationPath) return;
    setPublishing(true);
    setActionError(undefined);
    try {
      const baseUrl = await discoveryApi.getBaseUrl('api-monetization');
      const response = await fetchApi.fetch(`${baseUrl}${publicationPath}`, { method: 'POST' });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(body.error?.message || body.error || `Publication failed: HTTP ${response.status}`);
      setRefresh(value => value + 1);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    } finally {
      setPublishing(false);
    }
  };

  if (!devSpacesUrl) {
    return null;
  }

  return (
    <Card>
      <CardContent>
        <Typography variant="h5" component="h2" gutterBottom>
          OpenShift Dev Spaces
        </Typography>
        <Typography variant="body2" color="textSecondary">
          Develop this API in an OpenShift-hosted workspace using the repository&apos;s devfile.
        </Typography>
        {publication.value && (
          <Box mt={2}>
            <Chip
              size="small"
              color={publication.value.phase === 'ready' ? 'primary' : 'default'}
              label={publication.value.phase === 'ready'
                ? 'Published and healthy'
                : publication.value.phase === 'deploying'
                  ? `${publication.value.syncStatus || 'Syncing'} · ${publication.value.healthStatus || 'Progressing'}`
                  : publication.value.phase === 'failed'
                    ? 'Publication failed'
                    : 'Not published'}
            />
            {publication.value.apiKeyEndpoint && (
              <Typography variant="body2" color="textSecondary">
                API key: {publication.value.apiKeyEndpoint}
              </Typography>
            )}
            {publication.value.jwtEndpoint && (
              <Typography variant="body2" color="textSecondary">
                Keycloak JWT: {publication.value.jwtEndpoint}
              </Typography>
            )}
          </Box>
        )}
        {(publication.error || actionError) && (
          <Box mt={2}>
            <Typography variant="body2" color="error">
              {actionError || publication.error?.message}
            </Typography>
          </Box>
        )}
      </CardContent>
      <CardActions>
        <Button
          color="primary"
          href={devSpacesUrl}
          startIcon={<LaunchIcon />}
          variant="contained"
        >
          Open in Dev Spaces
        </Button>
        <Button
          color="primary"
          disabled={publishing || publication.loading || publication.value?.phase === 'ready'}
          onClick={publication.value?.phase === 'deploying'
            ? () => setRefresh(value => value + 1)
            : publish}
          startIcon={<PublishIcon />}
          variant="outlined"
        >
          {publishing
            ? 'Validating…'
            : publication.value?.phase === 'deploying'
              ? 'Check now'
              : publication.value?.phase === 'failed'
                ? 'Retry publication'
                : 'Publish API'}
        </Button>
      </CardActions>
    </Card>
  );
};

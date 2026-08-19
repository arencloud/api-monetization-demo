import { useEntity } from '@backstage/plugin-catalog-react';
import { Button, Card, CardActions, CardContent, Typography } from '@material-ui/core';
import LaunchIcon from '@material-ui/icons/Launch';
import React from 'react';
import { devSpacesUrlForProject } from '../devspaces';

export const EntityDevSpacesCard = () => {
  const { entity } = useEntity();
  const projectSlug = entity.metadata.annotations?.['github.com/project-slug'];
  const devSpacesUrl = devSpacesUrlForProject(projectSlug);

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
      </CardActions>
    </Card>
  );
};

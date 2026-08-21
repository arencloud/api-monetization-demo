import { CardTab, TabbedCard } from "@backstage/core-components";
import {
  OpenApiDefinitionWidget,
  PlainApiDefinitionWidget,
} from "@backstage/plugin-api-docs";
import { useEntity } from "@backstage/plugin-catalog-react";
import React, { useMemo } from "react";
import {
  addApiKeyAuthorizationPrefix,
  usesApiKeyAuthorization,
} from "../swaggerAuthorization";

export const EntityMonetizedApiDefinition = () => {
  const { entity } = useEntity();
  const definition = String(entity.spec?.definition ?? "");
  const apiKeyAuthorization = useMemo(
    () => usesApiKeyAuthorization(definition),
    [definition]
  );
  const title = entity.metadata.title ?? entity.metadata.name;

  const requestInterceptor = useMemo(
    () => (request: { headers?: Record<string, unknown> }) =>
      addApiKeyAuthorizationPrefix(request, apiKeyAuthorization),
    [apiKeyAuthorization]
  );

  if (String(entity.spec?.type).toLowerCase() !== "openapi") {
    return (
      <TabbedCard title={title}>
        {[
          <CardTab
            key="definition"
            label={String(entity.spec?.type ?? "Definition")}
          >
            <PlainApiDefinitionWidget
              definition={definition}
              language={String(entity.spec?.type ?? "text")}
            />
          </CardTab>,
        ]}
      </TabbedCard>
    );
  }

  return (
    <TabbedCard title={title}>
      <CardTab label="OpenAPI">
        <OpenApiDefinitionWidget
          definition={definition}
          requestInterceptor={requestInterceptor}
        />
      </CardTab>
      <CardTab label="Raw">
        <PlainApiDefinitionWidget definition={definition} language="yaml" />
      </CardTab>
    </TabbedCard>
  );
};

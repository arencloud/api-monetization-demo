type OpenApiSecurityScheme = {
  type?: unknown;
  in?: unknown;
  name?: unknown;
};

type OpenApiDocument = {
  components?: {
    securitySchemes?: Record<string, OpenApiSecurityScheme>;
  };
};

export type SwaggerRequest = {
  headers?: Record<string, unknown>;
};

const apiKeyAuthorizationScheme = (document: OpenApiDocument): boolean =>
  Object.values(document.components?.securitySchemes ?? {}).some(
    (scheme) =>
      scheme.type === "apiKey" &&
      scheme.in === "header" &&
      typeof scheme.name === "string" &&
      scheme.name.toLowerCase() === "authorization"
  );

export const usesApiKeyAuthorization = (definition: string): boolean => {
  try {
    return apiKeyAuthorizationScheme(JSON.parse(definition) as OpenApiDocument);
  } catch {
    // Catalog OpenAPI definitions are normally YAML. Avoid pulling a second
    // parser into the browser bundle: the security-scheme block is deliberately
    // small and emitted by the governed Golden Paths in a stable form.
    const securitySchemes = definition.match(
      /(?:^|\n)\s*securitySchemes:\s*\n([\s\S]*?)(?=\n\S|$)/
    )?.[1];
    if (!securitySchemes) return false;

    return (
      /(?:^|\n)\s*type:\s*apiKey\s*(?:#.*)?$/m.test(securitySchemes) &&
      /(?:^|\n)\s*in:\s*header\s*(?:#.*)?$/m.test(securitySchemes) &&
      /(?:^|\n)\s*name:\s*["']?Authorization["']?\s*(?:#.*)?$/im.test(
        securitySchemes
      )
    );
  }
};

export const addApiKeyAuthorizationPrefix = <T extends SwaggerRequest>(
  request: T,
  enabled: boolean
): T => {
  if (!enabled || !request.headers) return request;

  const headerName = Object.keys(request.headers).find(
    (name) => name.toLowerCase() === "authorization"
  );
  if (!headerName) return request;

  const value = request.headers[headerName];
  if (typeof value !== "string") return request;

  const credential = value.trim();
  if (!credential || /^APIKEY\s+/i.test(credential)) return request;

  request.headers[headerName] = `APIKEY ${credential}`;
  return request;
};

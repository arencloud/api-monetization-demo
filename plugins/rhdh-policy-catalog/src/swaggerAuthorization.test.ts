import {
  addApiKeyAuthorizationPrefix,
  usesApiKeyAuthorization,
} from "./swaggerAuthorization";

const apiKeyDefinition = `
openapi: 3.0.3
components:
  securitySchemes:
    apiKey:
      type: apiKey
      in: header
      name: Authorization
`;

const jwtDefinition = `
openapi: 3.0.3
components:
  securitySchemes:
    bearer:
      type: http
      scheme: bearer
`;

describe("Swagger authorization", () => {
  it("recognizes governed Authorization-header API-key contracts", () => {
    expect(usesApiKeyAuthorization(apiKeyDefinition)).toBe(true);
    expect(usesApiKeyAuthorization(jwtDefinition)).toBe(false);
  });

  it("recognizes equivalent JSON OpenAPI contracts", () => {
    expect(
      usesApiKeyAuthorization(
        JSON.stringify({
          components: {
            securitySchemes: {
              apiKey: { type: "apiKey", in: "header", name: "Authorization" },
            },
          },
        })
      )
    ).toBe(true);
  });

  it("adds the RHCL APIKEY prefix to a bare Swagger credential", () => {
    const request = { headers: { Authorization: "secret-value" } };

    expect(
      addApiKeyAuthorizationPrefix(request, true).headers.Authorization
    ).toBe("APIKEY secret-value");
  });

  it("preserves an existing prefix and JWT authorization", () => {
    const prefixed = { headers: { Authorization: "APIKEY secret-value" } };
    const jwt = { headers: { Authorization: "Bearer token-value" } };

    expect(addApiKeyAuthorizationPrefix(prefixed, true)).toBe(prefixed);
    expect(addApiKeyAuthorizationPrefix(jwt, false)).toBe(jwt);
    expect(jwt.headers.Authorization).toBe("Bearer token-value");
  });

  it("handles case-insensitive Authorization header names", () => {
    const request = { headers: { authorization: "secret-value" } };

    expect(
      addApiKeyAuthorizationPrefix(request, true).headers.authorization
    ).toBe("APIKEY secret-value");
  });
});

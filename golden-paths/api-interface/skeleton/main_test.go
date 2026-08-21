package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAPIContractEndpoint(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "${{ values.apiPath }}", nil)
	response := httptest.NewRecorder()
	routes().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if !strings.Contains(response.Body.String(), `"api":"${{ values.name }}"`) {
		t.Fatalf("unexpected response: %s", response.Body.String())
	}
}

func TestHealthAndOpenAPI(t *testing.T) {
	for _, path := range []string{"/healthz", "/readyz", "/openapi.yaml", "/openapi/api-key.yaml", "/openapi/keycloak-jwt.yaml"} {
		response := httptest.NewRecorder()
		routes().ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusOK {
			t.Fatalf("%s status = %d, want %d", path, response.Code, http.StatusOK)
		}
	}
}

func TestAuthenticationSpecificOpenAPI(t *testing.T) {
	t.Setenv("API_KEY_BASE_URL", "https://api.apps.example.test")
	t.Setenv("JWT_BASE_URL", "https://jwt.apps.example.test")

	apiKey := httptest.NewRecorder()
	routes().ServeHTTP(apiKey, httptest.NewRequest(http.MethodGet, "/openapi/api-key.yaml", nil))
	if !strings.Contains(apiKey.Body.String(), "type: apiKey") || strings.Contains(apiKey.Body.String(), "scheme: bearer") {
		t.Fatalf("API-key contract exposes the wrong security scheme: %s", apiKey.Body.String())
	}
	if !strings.Contains(apiKey.Body.String(), "https://api.apps.example.test") {
		t.Fatalf("API-key contract does not expose the admitted endpoint")
	}

	jwt := httptest.NewRecorder()
	routes().ServeHTTP(jwt, httptest.NewRequest(http.MethodGet, "/openapi/keycloak-jwt.yaml", nil))
	if !strings.Contains(jwt.Body.String(), "scheme: bearer") || strings.Contains(jwt.Body.String(), "type: apiKey") {
		t.Fatalf("JWT contract exposes the wrong security scheme: %s", jwt.Body.String())
	}
	if !strings.Contains(jwt.Body.String(), "https://jwt.apps.example.test") {
		t.Fatalf("JWT contract does not expose the admitted endpoint")
	}
}

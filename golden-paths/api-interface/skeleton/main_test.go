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
	for _, path := range []string{"/healthz", "/readyz", "/openapi.yaml"} {
		response := httptest.NewRecorder()
		routes().ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusOK {
			t.Fatalf("%s status = %d, want %d", path, response.Code, http.StatusOK)
		}
	}
}


package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestValidIdentifier(t *testing.T) {
	t.Parallel()
	tests := map[string]bool{
		"free":          true,
		"business":      true,
		"custom-tier":   true,
		"":              false,
		"Business":      false,
		"enterprise_2":  false,
		"invalid tier":  false,
		"../../secrets": false,
	}
	for value, expected := range tests {
		if actual := validIdentifier(value); actual != expected {
			t.Errorf("validIdentifier(%q)=%v, want %v", value, actual, expected)
		}
	}
}

func TestBearerToken(t *testing.T) {
	t.Parallel()
	tests := map[string]struct {
		header string
		want   string
		valid  bool
	}{
		"standard":         {header: "Bearer signed-token", want: "signed-token", valid: true},
		"case insensitive": {header: "bearer signed-token", want: "signed-token", valid: true},
		"missing":          {header: "", valid: false},
		"wrong scheme":     {header: "Basic signed-token", valid: false},
		"extra field":      {header: "Bearer token extra", valid: false},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got, err := bearerToken(test.header)
			if (err == nil) != test.valid {
				t.Fatalf("bearerToken(%q) error=%v, valid=%v", test.header, err, test.valid)
			}
			if got != test.want {
				t.Errorf("bearerToken(%q)=%q, want %q", test.header, got, test.want)
			}
		})
	}
}

func TestContainsRole(t *testing.T) {
	t.Parallel()
	if !contains([]string{"offline_access", portalAdminRole}, portalAdminRole) {
		t.Fatal("expected administrator role to be found")
	}
	if contains([]string{"plan-free"}, portalAdminRole) {
		t.Fatal("unexpected administrator role was found")
	}
}

func TestChangeAPIKeyPlanUpdatesAPIKeyTier(t *testing.T) {
	t.Parallel()

	apiKeyPatched := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPatch && r.URL.Path == "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeys/demo-inventory-key":
			apiKeyPatched = true
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	err := client.changeAPIKeyPlan(context.Background(), "api-monetization-apps", "demo-inventory-key", "developer")
	if err != nil {
		t.Fatalf("changeAPIKeyPlan returned error: %v", err)
	}
	if !apiKeyPatched {
		t.Fatal("APIKey plan tier was not patched")
	}
}

func TestRouteHostRequiresAdmittedRoute(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apis/route.openshift.io/v1/namespaces/api-monetization-identity/routes/api-monetization-keycloak" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"status":{"ingress":[{"host":"keycloak.example.test","conditions":[{"type":"Admitted","status":"True"}]}]}}`)
	}))
	defer server.Close()

	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	host, err := client.routeHost(context.Background(), keycloakNamespace, keycloakRouteName)
	if err != nil {
		t.Fatalf("routeHost returned error: %v", err)
	}
	if host != "keycloak.example.test" {
		t.Fatalf("routeHost=%q, want keycloak.example.test", host)
	}
}

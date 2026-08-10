package main

import (
	"context"
	"encoding/json"
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

func TestChangeAPIKeyPlanUsesSpecSecretReference(t *testing.T) {
	t.Parallel()

	secretPatched := false
	apiKeyPatched := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeys/demo-inventory-key":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"spec": map[string]any{
					"planTier":  "free",
					"secretRef": map[string]string{"name": "demo-inventory-api-key"},
				},
			})
		case r.Method == http.MethodPatch && r.URL.Path == "/api/v1/namespaces/api-monetization-apps/secrets/demo-inventory-api-key":
			secretPatched = true
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodPatch && r.URL.Path == "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeys/demo-inventory-key":
			apiKeyPatched = true
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	secretName, err := client.changeAPIKeyPlan(context.Background(), "api-monetization-apps", "demo-inventory-key", "developer")
	if err != nil {
		t.Fatalf("changeAPIKeyPlan returned error: %v", err)
	}
	if secretName != "demo-inventory-api-key" {
		t.Fatalf("secret name = %q, want demo-inventory-api-key", secretName)
	}
	if !secretPatched || !apiKeyPatched {
		t.Fatalf("patches applied: secret=%v APIKey=%v, want both true", secretPatched, apiKeyPatched)
	}
}

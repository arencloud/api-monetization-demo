package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSelfServiceResourceNames(t *testing.T) {
	t.Parallel()
	customer := selfServiceCustomerID("8c6e4fd5-29b0-4b76-aef8-844675131d3f")
	if !validIdentifier(customer) {
		t.Fatalf("self-service customer ID %q is not a valid entitlement identifier", customer)
	}
	if len(customer) != 28 {
		t.Fatalf("self-service customer ID length=%d, want 28", len(customer))
	}
	apiKey, secret := selfServiceResourceNames(customer, "inventory")
	if apiKey != customer+"-inventory" || secret != customer+"-inventory-key" {
		t.Fatalf("unexpected resource names: apiKey=%q secret=%q", apiKey, secret)
	}
}

func TestSelfServiceProducts(t *testing.T) {
	t.Parallel()
	tests := []struct {
		product    string
		apiProduct string
		endpoint   string
	}{
		{product: "inventory", apiProduct: "inventory-api", endpoint: "https://api.example/inventory"},
		{product: "payments", apiProduct: "payments-api", endpoint: "https://api.example/payments"},
		{product: "ai-chat", apiProduct: "ai-chat-api", endpoint: "https://api.example/v1/chat/completions"},
	}
	for _, test := range tests {
		definition, available := selfServiceProducts[test.product]
		if !available || definition.APIProduct != test.apiProduct {
			t.Errorf("product %q definition=%+v available=%v", test.product, definition, available)
		}
		if got := endpointFor("api.example", test.product); got != test.endpoint {
			t.Errorf("endpointFor product %q=%q, want %q", test.product, got, test.endpoint)
		}
	}
	if selfServiceProductAvailable("missing") {
		t.Error("unknown products must remain unavailable")
	}
}

func TestCurrentBillingPeriodUsesUTCMonth(t *testing.T) {
	t.Parallel()
	start, end := currentBillingPeriod(time.Date(2026, time.March, 31, 23, 30, 0, 0, time.FixedZone("UTC-2", -2*60*60)))
	if got := start.Format(time.RFC3339); got != "2026-04-01T00:00:00Z" {
		t.Fatalf("billing period start=%s", got)
	}
	if got := end.Format(time.RFC3339); got != "2026-05-01T00:00:00Z" {
		t.Fatalf("billing period end=%s", got)
	}
}

func TestRoundMicrosToCents(t *testing.T) {
	t.Parallel()
	tests := map[int64]int64{0: 0, 4999: 0, 5000: 1, 10000: 1, 14999: 1, 15000: 2, 25000: 3}
	for micros, want := range tests {
		if got := roundMicrosToCents(micros); got != want {
			t.Errorf("roundMicrosToCents(%d)=%d, want %d", micros, got, want)
		}
	}
}

func TestCreateIfAbsentAcceptsConflict(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/json" {
			t.Fatalf("unexpected request: method=%s content-type=%s", r.Method, r.Header.Get("Content-Type"))
		}
		w.WriteHeader(http.StatusConflict)
	}))
	defer server.Close()
	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	if err := client.createIfAbsent(context.Background(), "/resource", map[string]string{"name": "existing"}); err != nil {
		t.Fatalf("createIfAbsent returned conflict error: %v", err)
	}
}

func TestDeleteIfExistsAcceptsMissingResource(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			t.Fatalf("unexpected method: %s", r.Method)
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	if err := client.deleteIfExists(context.Background(), "/resource"); err != nil {
		t.Fatalf("deleteIfExists returned not-found error: %v", err)
	}
}

func TestDeleteIfExistsDeletesResource(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			t.Fatalf("unexpected method: %s", r.Method)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	if err := client.deleteIfExists(context.Background(), "/resource"); err != nil {
		t.Fatalf("deleteIfExists returned error: %v", err)
	}
}

func TestKubeRequestRetriesTooManyRequests(t *testing.T) {
	t.Parallel()
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if r.Method != http.MethodGet {
			t.Fatalf("unexpected method: %s", r.Method)
		}
		if attempts < 3 {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"message":"storage is (re)initializing"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ready"}`))
	}))
	defer server.Close()
	client := &kubeClient{
		baseURL: server.URL, token: "test", client: server.Client(),
		throttleRetryWait: time.Millisecond,
	}
	var result map[string]string
	if err := client.request(context.Background(), http.MethodGet, "/resource", nil, &result); err != nil {
		t.Fatalf("request returned error after transient throttling: %v", err)
	}
	if attempts != 3 || result["status"] != "ready" {
		t.Fatalf("attempts=%d result=%v, want 3 attempts and ready status", attempts, result)
	}
}

func TestDeleteDeveloperCredentialRemovesPortalRequestArtifacts(t *testing.T) {
	t.Parallel()
	const namespace = "api-monetization-apps"
	const apiKeyName = "dev-test-inventory"
	const requestName = "api-monetization-apps-dev-test-inventory-12345678"
	const approvalName = requestName + "-auto"
	deleted := make(map[string]bool)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeyrequests":
			fmt.Fprintf(w, `{"items":[{"metadata":{"name":%q},"spec":{"apiKeyRef":{"name":%q,"namespace":%q}}},{"metadata":{"name":"unrelated"},"spec":{"apiKeyRef":{"name":"another-key","namespace":%q}}}]}`, requestName, apiKeyName, namespace, namespace)
			return
		case "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeyapprovals":
			fmt.Fprintf(w, `{"items":[{"metadata":{"name":%q},"spec":{"apiKeyRequestRef":{"name":%q}}},{"metadata":{"name":"unrelated-auto"},"spec":{"apiKeyRequestRef":{"name":"unrelated"}}}]}`, approvalName, requestName)
			return
		}
		if r.Method == http.MethodDelete {
			deleted[r.URL.Path] = true
			w.WriteHeader(http.StatusOK)
			return
		}
		if r.Method == http.MethodGet && deleted[r.URL.Path] {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()
	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	if err := client.deleteDeveloperCredential(context.Background(), namespace, apiKeyName, apiKeyName+"-key"); err != nil {
		t.Fatalf("deleteDeveloperCredential returned error: %v", err)
	}
	requestPath := "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeyrequests/" + requestName
	approvalPath := "/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeyapprovals/" + approvalName
	if !deleted[requestPath] || !deleted[approvalPath] {
		t.Fatalf("portal artifacts were not deleted: request=%v approval=%v", deleted[requestPath], deleted[approvalPath])
	}
	if deleted["/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeyrequests/unrelated"] ||
		deleted["/apis/devportal.kuadrant.io/v1alpha1/namespaces/api-monetization-apps/apikeyapprovals/unrelated-auto"] {
		t.Fatal("unrelated portal artifacts were deleted")
	}
}

func TestSecretValueDecodesAPIKey(t *testing.T) {
	t.Parallel()
	want := "generated-api-key"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"data":{"api_key":%q}}`, base64.StdEncoding.EncodeToString([]byte(want)))
	}))
	defer server.Close()
	client := &kubeClient{baseURL: server.URL, token: "test", client: server.Client()}
	got, err := client.secretValue(context.Background(), "namespace", "credential", "api_key")
	if err != nil || got != want {
		t.Fatalf("secretValue=%q, error=%v, want %q", got, err, want)
	}
}

func TestValidIdentifier(t *testing.T) {
	t.Parallel()
	tests := map[string]bool{
		"free":          true,
		"business":      true,
		"custom-tier":   true,
		"dev-a1820f":    true,
		"":              false,
		"Business":      false,
		"enterprise_2":  false,
		"invalid tier":  false,
		"../../secrets": false,
		"-invalid":      false,
		"invalid-":      false,
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

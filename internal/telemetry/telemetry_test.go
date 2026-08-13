package telemetry

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMiddlewareRecordsPlanAndCustomer(t *testing.T) {
	t.Parallel()
	recorder := New("test-api")
	handler := recorder.Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
	}))
	request := httptest.NewRequest(http.MethodGet, "/inventory", nil)
	request.Header.Set("x-monetization-plan", "developer")
	request.Header.Set("x-monetization-customer", "demo-company")
	handler.ServeHTTP(httptest.NewRecorder(), request)

	metrics := httptest.NewRecorder()
	recorder.Handler(metrics, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := metrics.Body.String()
	for _, expected := range []string{`plan="developer"`, `customer="demo-company"`, `status="201"`} {
		if !strings.Contains(body, expected) {
			t.Fatalf("metrics missing %s: %s", expected, body)
		}
	}
}

func TestProductName(t *testing.T) {
	t.Parallel()
	for path, want := range map[string]string{
		"/inventory":          "inventory",
		"/inventory/RHCL-001": "inventory",
		"/payments":           "payments",
		"/payments/pay-1001":  "payments",
		"/healthz":            "",
	} {
		if got := productName(path); got != want {
			t.Errorf("productName(%q)=%q, want %q", path, got, want)
		}
	}
}

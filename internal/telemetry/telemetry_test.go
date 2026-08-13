package telemetry

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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

func TestMiddlewareExportsNativeBillableUnits(t *testing.T) {
	events := make(chan usageEvent, 1)
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var event usageEvent
		if err := json.NewDecoder(r.Body).Decode(&event); err != nil {
			t.Errorf("decode usage event: %v", err)
		}
		events <- event
		w.WriteHeader(http.StatusCreated)
	}))
	defer sink.Close()
	t.Setenv("USAGE_SINK_URL", sink.URL)

	recorder := New("ai-chat-api")
	handler := recorder.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !SetBillableUsage(r, 37, map[string]any{"promptTokens": 20, "completionTokens": 17}) {
			t.Fatal("request did not contain usage details")
		}
		w.WriteHeader(http.StatusOK)
	}))
	request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	request.Header.Set("x-monetization-plan", "developer")
	request.Header.Set("x-monetization-customer", "demo-company")
	handler.ServeHTTP(httptest.NewRecorder(), request)

	select {
	case event := <-events:
		if event.Product != "ai-chat" || event.BillableUnits != 37 {
			t.Fatalf("event=%+v, want ai-chat with 37 units", event)
		}
		if event.Attributes["completionTokens"] != float64(17) {
			t.Fatalf("attributes=%v, want completionTokens=17", event.Attributes)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("usage event was not exported")
	}
}

func TestProductName(t *testing.T) {
	t.Parallel()
	for path, want := range map[string]string{
		"/inventory":           "inventory",
		"/inventory/RHCL-001":  "inventory",
		"/payments":            "payments",
		"/payments/pay-1001":   "payments",
		"/v1/chat/completions": "ai-chat",
		"/healthz":             "",
	} {
		if got := productName(path); got != want {
			t.Errorf("productName(%q)=%q, want %q", path, got, want)
		}
	}
}

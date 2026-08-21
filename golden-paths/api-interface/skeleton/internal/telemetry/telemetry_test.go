package telemetry

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestAcceptedAuthenticatedRequestExportsOneUnit(t *testing.T) {
	events := make(chan usageEvent, 1)
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var event usageEvent
		if err := json.NewDecoder(r.Body).Decode(&event); err != nil {
			t.Error(err)
		}
		events <- event
		w.WriteHeader(http.StatusCreated)
	}))
	defer sink.Close()
	t.Setenv("USAGE_SINK_URL", sink.URL)
	t.Setenv("MONETIZATION_PRODUCT", "orders")
	t.Setenv("MONETIZATION_UNIT", "request")
	handler := New("orders", "orders").Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	request := httptest.NewRequest(http.MethodGet, "/orders", nil)
	request.Header.Set("x-request-id", "request-1")
	request.Header.Set("x-monetization-customer", "consumer-1")
	request.Header.Set("x-monetization-plan", "payg")
	handler.ServeHTTP(httptest.NewRecorder(), request)
	select {
	case event := <-events:
		if event.Product != "orders" || event.BillableUnits != 1 {
			t.Fatalf("event=%+v", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("usage event was not exported")
	}
}

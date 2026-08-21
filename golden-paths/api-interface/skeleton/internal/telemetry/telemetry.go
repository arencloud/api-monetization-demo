package telemetry

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

type Recorder struct {
	product string
	sinkURL string
	client  *http.Client
	events  chan usageEvent
}

type usageEvent struct {
	RequestID     string         `json:"requestId"`
	Customer      string         `json:"customer"`
	Plan          string         `json:"plan"`
	Product       string         `json:"product"`
	Operation     string         `json:"operation"`
	OccurredAt    time.Time      `json:"occurredAt"`
	StatusCode    int            `json:"statusCode"`
	DurationMS    float64        `json:"durationMs"`
	RequestBytes  int64          `json:"requestBytes"`
	ResponseBytes int64          `json:"responseBytes"`
	BillableUnits int64          `json:"billableUnits"`
	Attributes    map[string]any `json:"attributes,omitempty"`
}

func New(service, fallbackProduct string) *Recorder {
	product := os.Getenv("MONETIZATION_PRODUCT")
	if product == "" {
		product = fallbackProduct
	}
	r := &Recorder{
		product: product,
		sinkURL: os.Getenv("USAGE_SINK_URL"),
		client:  &http.Client{Timeout: 3 * time.Second},
		events:  make(chan usageEvent, 256),
	}
	if r.sinkURL != "" {
		go r.export()
	}
	_ = service
	return r
}

func (r *Recorder) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		started := time.Now()
		requestID := request.Header.Get("x-request-id")
		if requestID == "" {
			requestID = fmt.Sprintf("local-%d", started.UnixNano())
		}
		wrapped := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(wrapped, request)
		customer := request.Header.Get("x-monetization-customer")
		if r.sinkURL == "" || customer == "" || r.product == "" {
			return
		}
		units := int64(0)
		if wrapped.status >= 200 && wrapped.status < 300 {
			units = 1
			if os.Getenv("MONETIZATION_UNIT") == "token" {
				// Token APIs must set this response header from actual model usage.
				if parsed, err := parseUnits(wrapped.Header().Get("X-Monetization-Billable-Units")); err == nil {
					units = parsed
				} else {
					units = 0
				}
			}
		}
		event := usageEvent{
			RequestID: requestID, Customer: customer,
			Plan: request.Header.Get("x-monetization-plan"), Product: r.product,
			Operation: request.Method + " " + request.URL.Path, OccurredAt: started.UTC(),
			StatusCode: wrapped.status, DurationMS: float64(time.Since(started).Microseconds()) / 1000,
			RequestBytes: max(request.ContentLength, 0), ResponseBytes: wrapped.bytes,
			BillableUnits: units,
		}
		select {
		case r.events <- event:
		default:
			log.Printf("usage export queue full for request %s", requestID)
		}
	})
}

func parseUnits(value string) (int64, error) {
	var units int64
	if _, err := fmt.Sscan(value, &units); err != nil || units < 0 {
		return 0, fmt.Errorf("invalid billable units")
	}
	return units, nil
}

func (r *Recorder) export() {
	for event := range r.events {
		body, err := json.Marshal(event)
		if err != nil {
			continue
		}
		request, err := http.NewRequest(http.MethodPost, r.sinkURL, bytes.NewReader(body))
		if err != nil {
			continue
		}
		request.Header.Set("Content-Type", "application/json")
		response, err := r.client.Do(request)
		if err != nil {
			log.Printf("usage export failed for %s: %v", event.RequestID, err)
			continue
		}
		_ = response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			log.Printf("usage export rejected for %s: HTTP %d", event.RequestID, response.StatusCode)
		}
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(body []byte) (int, error) {
	written, err := w.ResponseWriter.Write(body)
	w.bytes += int64(written)
	return written, err
}

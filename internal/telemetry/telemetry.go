package telemetry

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type Recorder struct {
	service string
	mu      sync.RWMutex
	counts  map[string]uint64
	durMS   map[string]float64
	sinkURL string
	sink    chan usageEvent
	client  *http.Client
}

func New(service string) *Recorder {
	recorder := &Recorder{
		service: service,
		counts:  map[string]uint64{},
		durMS:   map[string]float64{},
		sinkURL: os.Getenv("USAGE_SINK_URL"),
		sink:    make(chan usageEvent, 1024),
		client:  &http.Client{Timeout: 3 * time.Second},
	}
	if recorder.sinkURL != "" {
		go recorder.exportUsage()
	}
	return recorder
}

func (r *Recorder) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		started := time.Now()
		requestID := req.Header.Get("x-request-id")
		if requestID == "" {
			requestID = fmt.Sprintf("local-%d", started.UnixNano())
		}
		w.Header().Set("x-request-id", requestID)
		wrapped := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(wrapped, req)
		duration := time.Since(started)
		product := productName(req.URL.Path)
		plan := cleanLabel(req.Header.Get("x-monetization-plan"), "unknown")
		customer := cleanLabel(req.Header.Get("x-monetization-customer"), "anonymous")
		key := strings.Join([]string{req.Method, routeName(req.URL.Path), fmt.Sprint(wrapped.status), plan, customer}, "\x00")
		r.mu.Lock()
		r.counts[key]++
		r.durMS[key] += float64(duration.Microseconds()) / 1000
		r.mu.Unlock()
		if r.sinkURL != "" && customer != "anonymous" && product != "" {
			event := usageEvent{
				RequestID:     requestID,
				Customer:      customer,
				Plan:          plan,
				Product:       product,
				Operation:     req.Method + " " + routeName(req.URL.Path),
				OccurredAt:    started.UTC(),
				StatusCode:    wrapped.status,
				DurationMS:    float64(duration.Microseconds()) / 1000,
				ResponseBytes: wrapped.bytes,
			}
			select {
			case r.sink <- event:
			default:
				slog.Warn("usage export queue full", "request_id", requestID)
			}
		}
		slog.Info("request completed",
			"service", r.service,
			"request_id", requestID,
			"traceparent", req.Header.Get("traceparent"),
			"method", req.Method,
			"path", req.URL.Path,
			"status", wrapped.status,
			"duration_ms", duration.Milliseconds(),
			"customer", customer,
			"plan", plan,
		)
	})
}

type usageEvent struct {
	RequestID     string    `json:"requestId"`
	Customer      string    `json:"customer"`
	Plan          string    `json:"plan"`
	Product       string    `json:"product"`
	Operation     string    `json:"operation"`
	OccurredAt    time.Time `json:"occurredAt"`
	StatusCode    int       `json:"statusCode"`
	DurationMS    float64   `json:"durationMs"`
	ResponseBytes int64     `json:"responseBytes"`
}

func (r *Recorder) exportUsage() {
	for event := range r.sink {
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
			slog.Warn("usage export failed", "request_id", event.RequestID, "error", err)
			continue
		}
		_ = response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			slog.Warn("usage export rejected", "request_id", event.RequestID, "status", response.StatusCode)
		}
	}
}

func (r *Recorder) Handler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	r.mu.RLock()
	defer r.mu.RUnlock()
	keys := make([]string, 0, len(r.counts))
	for key := range r.counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	fmt.Fprintln(w, "# HELP api_requests_total Requests handled by the demo services.")
	fmt.Fprintln(w, "# TYPE api_requests_total counter")
	for _, key := range keys {
		parts := strings.Split(key, "\x00")
		labels := metricLabels(parts)
		fmt.Fprintf(w, "api_requests_total{%s,service=%q} %d\n", labels, r.service, r.counts[key])
	}
	fmt.Fprintln(w, "# HELP api_request_duration_milliseconds_total Cumulative request duration.")
	fmt.Fprintln(w, "# TYPE api_request_duration_milliseconds_total counter")
	for _, key := range keys {
		parts := strings.Split(key, "\x00")
		labels := metricLabels(parts)
		fmt.Fprintf(w, "api_request_duration_milliseconds_total{%s,service=%q} %.3f\n", labels, r.service, r.durMS[key])
	}
}

func metricLabels(parts []string) string {
	return fmt.Sprintf("method=%q,operation=%q,status=%q,plan=%q,customer=%q", parts[0], parts[1], parts[2], parts[3], parts[4])
}

func cleanLabel(value, fallback string) string {
	if value == "" {
		return fallback
	}
	if len(value) > 80 {
		return value[:80]
	}
	return value
}

func routeName(path string) string {
	switch {
	case strings.HasPrefix(path, "/inventory"):
		return "inventory"
	case strings.HasPrefix(path, "/payments"):
		return "payments"
	case strings.HasPrefix(path, "/api/subscriptions"):
		return "subscriptions"
	case strings.HasPrefix(path, "/api/plans"):
		return "plans"
	case path == "/healthz" || path == "/readyz":
		return "health"
	default:
		return "other"
	}
}

func productName(path string) string {
	switch {
	case strings.HasPrefix(path, "/inventory"):
		return "inventory"
	case strings.HasPrefix(path, "/payments"):
		return "payments"
	default:
		return ""
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

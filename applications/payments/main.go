package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/arencloud/api-monetization-demo/internal/telemetry"
)

type payment struct {
	ID       string `json:"id"`
	OrderID  string `json:"orderId"`
	Amount   int64  `json:"amountCents"`
	Currency string `json:"currency"`
	Status   string `json:"status"`
}

func main() {
	recorder := telemetry.New("payments-api")
	apiMux := http.NewServeMux()
	apiMux.HandleFunc("GET /healthz", health)
	apiMux.HandleFunc("GET /readyz", health)
	apiMux.HandleFunc("GET /payments", payments)
	apiMux.HandleFunc("GET /payments/{id}", paymentByID)
	apiMux.HandleFunc("OPTIONS /payments", preflight)
	apiMux.HandleFunc("OPTIONS /payments/{id}", preflight)
	registerOpenAPI(apiMux)
	apiMux.HandleFunc("GET /metrics", recorder.Handler)
	apiServer := &http.Server{
		Addr: env("HTTP_ADDR", ":8080"), Handler: recorder.Middleware(apiMux),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}

	docsMux := http.NewServeMux()
	docsMux.HandleFunc("GET /healthz", health)
	registerOpenAPI(docsMux)
	docsServer := &http.Server{
		Addr: env("DOCS_ADDR", ":8082"), Handler: docsMux,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	errors := make(chan error, 2)
	start := func(name string, server *http.Server) {
		go func() {
			slog.Info(name+" listening", "address", server.Addr)
			errors <- server.ListenAndServe()
		}()
	}
	start("payments API", apiServer)
	start("payments OpenAPI documentation", docsServer)
	if err := <-errors; err != nil && err != http.ErrServerClosed {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func payments(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"payments": paymentData(), "count": len(paymentData())})
}

func paymentByID(w http.ResponseWriter, r *http.Request) {
	for _, candidate := range paymentData() {
		if candidate.ID == r.PathValue("id") {
			writeJSON(w, http.StatusOK, candidate)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "payment not found"})
}

func paymentData() []payment {
	return []payment{
		{ID: "pay-1001", OrderID: "order-4711", Amount: 12900, Currency: "EUR", Status: "authorized"},
		{ID: "pay-1002", OrderID: "order-4712", Amount: 4900, Currency: "EUR", Status: "settled"},
		{ID: "pay-1003", OrderID: "order-4713", Amount: 2499, Currency: "EUR", Status: "pending"},
	}
}

func health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func preflight(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNoContent)
}

func registerOpenAPI(mux *http.ServeMux) {
	mux.HandleFunc("GET /openapi.yaml", openAPI("api-key.yaml"))
	mux.HandleFunc("GET /openapi/api-key.yaml", openAPI("api-key.yaml"))
	mux.HandleFunc("GET /openapi/keycloak-jwt.yaml", openAPI("keycloak-jwt.yaml"))
}

func openAPI(filename string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/yaml")
		http.ServeFile(w, r, "/opt/app-root/src/openapi/"+filename)
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

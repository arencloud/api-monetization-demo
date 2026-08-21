package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/arencloud/api-monetization-demo/internal/telemetry"
)

type item struct {
	SKU       string `json:"sku"`
	Name      string `json:"name"`
	Available int    `json:"available"`
	Region    string `json:"region"`
}

func main() {
	recorder := telemetry.New("inventory-api")
	apiMux := http.NewServeMux()
	apiMux.HandleFunc("GET /healthz", health)
	apiMux.HandleFunc("GET /readyz", health)
	apiMux.HandleFunc("GET /inventory", inventory)
	apiMux.HandleFunc("GET /inventory/{sku}", inventoryItem)
	apiMux.HandleFunc("OPTIONS /inventory", preflight)
	apiMux.HandleFunc("OPTIONS /inventory/{sku}", preflight)
	registerOpenAPI(apiMux)
	apiMux.HandleFunc("GET /metrics", recorder.Handler)
	apiServer := &http.Server{
		Addr:              env("HTTP_ADDR", ":8080"),
		Handler:           recorder.Middleware(apiMux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	docsMux := http.NewServeMux()
	docsMux.HandleFunc("GET /healthz", health)
	registerOpenAPI(docsMux)
	docsServer := &http.Server{
		Addr:              env("DOCS_ADDR", ":8082"),
		Handler:           docsMux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errors := make(chan error, 2)
	startServer := func(name string, server *http.Server) {
		go func() {
			slog.Info(name+" listening", "address", server.Addr)
			errors <- server.ListenAndServe()
		}()
	}
	startServer("inventory API", apiServer)
	startServer("OpenAPI documentation", docsServer)

	if err := <-errors; err != nil && err != http.ErrServerClosed {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func inventory(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"items": inventoryData(),
		"count": len(inventoryData()),
	})
}

func inventoryItem(w http.ResponseWriter, r *http.Request) {
	for _, candidate := range inventoryData() {
		if candidate.SKU == r.PathValue("sku") {
			writeJSON(w, http.StatusOK, candidate)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "inventory item not found"})
}

func inventoryData() []item {
	region := env("REGION", "demo")
	return []item{
		{SKU: "RHCL-001", Name: "Connectivity Link", Available: 42, Region: region},
		{SKU: "OSSM-003", Name: "OpenShift Service Mesh", Available: 17, Region: region},
		{SKU: "RHBK-026", Name: "Red Hat build of Keycloak", Available: 26, Region: region},
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

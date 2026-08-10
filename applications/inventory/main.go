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
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", health)
	mux.HandleFunc("GET /readyz", health)
	mux.HandleFunc("GET /inventory", inventory)
	mux.HandleFunc("GET /inventory/{sku}", inventoryItem)
	mux.HandleFunc("GET /openapi.yaml", openAPI)
	mux.HandleFunc("GET /metrics", recorder.Handler)
	server := &http.Server{
		Addr:              env("HTTP_ADDR", ":8080"),
		Handler:           recorder.Middleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	slog.Info("inventory API listening", "address", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
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

func openAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/yaml")
	http.ServeFile(w, r, "/opt/app-root/src/openapi.yaml")
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

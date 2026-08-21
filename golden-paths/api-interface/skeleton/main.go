package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/${{ values.repoOwner }}/${{ values.name }}/internal/telemetry"
)

//go:embed openapi/api-key.yaml
var apiKeyOpenAPISpec []byte

//go:embed openapi/keycloak-jwt.yaml
var keycloakJWTOpenAPISpec []byte

var requestCount atomic.Uint64

func main() {
	recorder := telemetry.New("${{ values.name }}", "${{ values.name }}")
	mux := routes()
	apiServer := &http.Server{
		Addr:              env("HTTP_ADDR", ":8080"),
		Handler:           recorder.Middleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	docsMux := http.NewServeMux()
	docsMux.HandleFunc("GET /healthz", health)
	docsMux.HandleFunc("GET /openapi.yaml", openAPIDocument(apiKeyOpenAPISpec, "API_KEY_BASE_URL", "https://api.example.invalid"))
	docsMux.HandleFunc("GET /openapi/api-key.yaml", openAPIDocument(apiKeyOpenAPISpec, "API_KEY_BASE_URL", "https://api.example.invalid"))
	docsMux.HandleFunc("GET /openapi/keycloak-jwt.yaml", openAPIDocument(keycloakJWTOpenAPISpec, "JWT_BASE_URL", "https://jwt.api.example.invalid"))
	docsServer := &http.Server{
		Addr:              env("DOCS_ADDR", ":8082"),
		Handler:           docsMux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errors := make(chan error, 2)
	for name, server := range map[string]*http.Server{
		"API": apiServer, "OpenAPI documentation": docsServer,
	} {
		go func() {
			log.Printf("${{ values.name }} %s listening on %s", name, server.Addr)
			errors <- server.ListenAndServe()
		}()
	}
	if err := <-errors; err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", health)
	mux.HandleFunc("GET /readyz", health)
	mux.HandleFunc("GET /openapi.yaml", openAPIDocument(apiKeyOpenAPISpec, "API_KEY_BASE_URL", "https://api.example.invalid"))
	mux.HandleFunc("GET /openapi/api-key.yaml", openAPIDocument(apiKeyOpenAPISpec, "API_KEY_BASE_URL", "https://api.example.invalid"))
	mux.HandleFunc("GET /openapi/keycloak-jwt.yaml", openAPIDocument(keycloakJWTOpenAPISpec, "JWT_BASE_URL", "https://jwt.api.example.invalid"))
	mux.HandleFunc("GET /metrics", metrics)
	mux.HandleFunc("GET ${{ values.apiPath }}", api)
	return mux
}

func api(w http.ResponseWriter, r *http.Request) {
	requestCount.Add(1)
	writeJSON(w, http.StatusOK, map[string]any{
		"api":     "${{ values.name }}",
		"message": "Replace this handler with your contract implementation.",
		"request": r.Header.Get("x-request-id"),
	})
}

func health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func openAPIDocument(specification []byte, environmentName, placeholder string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		body := strings.ReplaceAll(string(specification), placeholder, env(environmentName, placeholder))
		w.Header().Set("Content-Type", "application/yaml")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body))
	}
}

func metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = fmt.Fprintf(w, "api_requests_total{api=%q} %d\n", "${{ values.name }}", requestCount.Load())
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

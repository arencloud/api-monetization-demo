package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

//go:embed openapi/openapi.yaml
var openAPISpec []byte

var requestCount atomic.Uint64

func main() {
	mux := routes()
	apiServer := &http.Server{
		Addr:              env("HTTP_ADDR", ":8080"),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	docsMux := http.NewServeMux()
	docsMux.HandleFunc("GET /healthz", health)
	docsMux.HandleFunc("GET /openapi.yaml", openAPI)
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
	mux.HandleFunc("GET /openapi.yaml", openAPI)
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

func openAPI(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/yaml")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(openAPISpec)
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

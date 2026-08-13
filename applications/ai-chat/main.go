package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/arencloud/api-monetization-demo/internal/telemetry"
)

const maxRequestBytes = 256 * 1024

type chatAPI struct {
	modelURL *url.URL
	client   *http.Client
}

type completionResponse struct {
	Model string `json:"model"`
	Usage struct {
		PromptTokens     int64 `json:"prompt_tokens"`
		CompletionTokens int64 `json:"completion_tokens"`
		TotalTokens      int64 `json:"total_tokens"`
	} `json:"usage"`
}

func main() {
	modelURL, err := url.Parse(env("MODEL_URL", "http://ai-chat-model-mtls.api-monetization-ai.svc.cluster.local:8080"))
	if err != nil || modelURL.Scheme != "http" || modelURL.Host == "" {
		slog.Error("invalid model URL", "value", modelURL, "error", err)
		os.Exit(1)
	}
	api := &chatAPI{
		modelURL: modelURL,
		client:   &http.Client{Timeout: 150 * time.Second},
	}
	recorder := telemetry.New("ai-chat-api")
	apiMux := http.NewServeMux()
	apiMux.HandleFunc("GET /healthz", health)
	apiMux.HandleFunc("GET /readyz", api.ready)
	apiMux.HandleFunc("POST /v1/chat/completions", api.chatCompletion)
	apiMux.HandleFunc("GET /metrics", recorder.Handler)
	apiServer := &http.Server{
		Addr:              env("HTTP_ADDR", ":8080"),
		Handler:           recorder.Middleware(apiMux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      180 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	docsMux := http.NewServeMux()
	docsMux.HandleFunc("GET /healthz", health)
	docsMux.HandleFunc("GET /openapi.yaml", openAPI)
	docsServer := &http.Server{
		Addr:              env("DOCS_ADDR", ":8082"),
		Handler:           docsMux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errors := make(chan error, 2)
	start := func(name string, server *http.Server) {
		go func() {
			slog.Info(name+" listening", "address", server.Addr)
			errors <- server.ListenAndServe()
		}()
	}
	start("AI Chat API", apiServer)
	start("AI Chat OpenAPI documentation", docsServer)
	if err = <-errors; err != nil && err != http.ErrServerClosed {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func (a *chatAPI) chatCompletion(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "chat request is too large"})
		return
	}
	var input map[string]any
	if err = json.Unmarshal(body, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid chat completion request"})
		return
	}
	messages, ok := input["messages"].([]any)
	if !ok || len(messages) == 0 {
		telemetry.SetBillableUsage(r, 0, map[string]any{"failure": "invalid-request"})
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "messages must be a non-empty array"})
		return
	}
	if streaming, _ := input["stream"].(bool); streaming {
		telemetry.SetBillableUsage(r, 0, map[string]any{"failure": "streaming-disabled"})
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "streaming is not enabled for token-metered demo requests"})
		return
	}
	input["model"] = "ai-chat"
	input["stream"] = false
	if requested, ok := input["max_tokens"].(float64); !ok || requested <= 0 {
		input["max_tokens"] = 16
	} else if requested > 64 {
		input["max_tokens"] = 64
	}
	body, err = json.Marshal(input)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid chat completion request"})
		return
	}

	endpoint := a.modelURL.ResolveReference(&url.URL{Path: "/v1/chat/completions"})
	request, err := http.NewRequestWithContext(r.Context(), http.MethodPost, endpoint.String(), bytes.NewReader(body))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "model request could not be created"})
		return
	}
	request.Header.Set("Content-Type", "application/json")
	for _, header := range []string{"x-request-id", "traceparent", "tracestate"} {
		if value := r.Header.Get(header); value != "" {
			request.Header.Set(header, value)
		}
	}
	response, err := a.client.Do(request)
	if err != nil {
		telemetry.SetBillableUsage(r, 0, map[string]any{"failure": "model-unavailable"})
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "model is unavailable"})
		return
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
	if err != nil {
		telemetry.SetBillableUsage(r, 0, map[string]any{"failure": "model-response"})
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "model returned an incomplete response"})
		return
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		telemetry.SetBillableUsage(r, 0, map[string]any{"upstreamStatus": response.StatusCode})
		copyModelResponse(w, response, responseBody)
		return
	}

	var completion completionResponse
	if err = json.Unmarshal(responseBody, &completion); err != nil {
		telemetry.SetBillableUsage(r, 0, map[string]any{"failure": "missing-usage"})
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "model response did not contain billable usage"})
		return
	}
	totalTokens := completion.Usage.TotalTokens
	if totalTokens == 0 {
		totalTokens = completion.Usage.PromptTokens + completion.Usage.CompletionTokens
	}
	if totalTokens <= 0 {
		telemetry.SetBillableUsage(r, 0, map[string]any{"failure": "missing-usage"})
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "model response did not contain billable usage"})
		return
	}
	telemetry.SetBillableUsage(r, totalTokens, map[string]any{
		"model":            completion.Model,
		"promptTokens":     completion.Usage.PromptTokens,
		"completionTokens": completion.Usage.CompletionTokens,
	})
	w.Header().Set("X-Monetization-Billable-Units", fmt.Sprint(totalTokens))
	copyModelResponse(w, response, responseBody)
}

func (a *chatAPI) ready(w http.ResponseWriter, r *http.Request) {
	endpoint := a.modelURL.ResolveReference(&url.URL{Path: "/health"})
	request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, endpoint.String(), nil)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "model unavailable"})
		return
	}
	response, err := a.client.Do(request)
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		if response != nil {
			_ = response.Body.Close()
		}
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "model unavailable"})
		return
	}
	_ = response.Body.Close()
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func copyModelResponse(w http.ResponseWriter, response *http.Response, body []byte) {
	contentType := response.Header.Get("Content-Type")
	if !strings.HasPrefix(contentType, "application/json") {
		contentType = "application/json"
	}
	w.Header().Set("Content-Type", contentType)
	w.WriteHeader(response.StatusCode)
	_, _ = w.Write(body)
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

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestChatCompletionForwardsAndReportsTokens(t *testing.T) {
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("path=%q", r.URL.Path)
		}
		var input map[string]any
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			t.Fatalf("decode input: %v", err)
		}
		if input["model"] != "ai-chat" || input["max_tokens"] != float64(64) {
			t.Fatalf("normalized request=%v", input)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"model":"ai-chat","choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12}}`))
	}))
	defer model.Close()
	modelURL, _ := url.Parse(model.URL)
	api := &chatAPI{modelURL: modelURL, client: &http.Client{Timeout: time.Second}}

	request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"ignored","max_tokens":1000,"messages":[{"role":"user","content":"hello"}]}`))
	response := httptest.NewRecorder()
	api.chatCompletion(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("X-Monetization-Billable-Units"); got != "12" {
		t.Fatalf("billable units=%q, want 12", got)
	}
}

func TestChatCompletionRejectsStreaming(t *testing.T) {
	api := &chatAPI{}
	request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"stream":true,"messages":[{"role":"user","content":"hello"}]}`))
	response := httptest.NewRecorder()
	api.chatCompletion(response, request)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "streaming") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

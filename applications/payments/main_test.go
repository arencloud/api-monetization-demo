package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPayments(t *testing.T) {
	t.Parallel()
	response := httptest.NewRecorder()
	payments(response, httptest.NewRequest(http.MethodGet, "/payments", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusOK)
	}
	if !strings.Contains(response.Body.String(), "pay-1001") {
		t.Fatalf("response does not contain seeded payment: %s", response.Body.String())
	}
}

func TestPaymentNotFound(t *testing.T) {
	t.Parallel()
	request := httptest.NewRequest(http.MethodGet, "/payments/missing", nil)
	request.SetPathValue("id", "missing")
	response := httptest.NewRecorder()
	paymentByID(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusNotFound)
	}
}

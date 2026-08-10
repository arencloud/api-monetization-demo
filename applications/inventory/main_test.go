package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestInventory(t *testing.T) {
	t.Parallel()
	response := httptest.NewRecorder()
	inventory(response, httptest.NewRequest(http.MethodGet, "/inventory", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusOK)
	}
	if !strings.Contains(response.Body.String(), "RHCL-001") {
		t.Fatalf("response does not contain seeded inventory: %s", response.Body.String())
	}
}

func TestInventoryItemNotFound(t *testing.T) {
	t.Parallel()
	request := httptest.NewRequest(http.MethodGet, "/inventory/missing", nil)
	request.SetPathValue("sku", "missing")
	response := httptest.NewRecorder()
	inventoryItem(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusNotFound)
	}
}

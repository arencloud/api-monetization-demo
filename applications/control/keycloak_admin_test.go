package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestOwnerApprovalChangesOnlyExpectedKeycloakGroups(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	mutations := make([]string, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/realms/api-monetization/protocol/openid-connect/token":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"access_token":"service-token","expires_in":300}`)
		case r.URL.Path == "/admin/realms/api-monetization/groups":
			name := r.URL.Query().Get("search")
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `[{"id":"%s-id","name":"%s"}]`, name, name)
		case r.Method == http.MethodPut || r.Method == http.MethodDelete:
			if r.Header.Get("Authorization") != "Bearer service-token" {
				http.Error(w, "missing service token", http.StatusUnauthorized)
				return
			}
			mu.Lock()
			mutations = append(mutations, r.Method+" "+r.URL.Path)
			mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client, err := newKeycloakAdminClient("secret")
	if err != nil {
		t.Fatal(err)
	}
	client.baseURL = server.URL
	if err = client.setOwner(context.Background(), "3f78ab4c-8a23-4efe-8477-74b8b45fc54f"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"PUT /admin/realms/api-monetization/users/3f78ab4c-8a23-4efe-8477-74b8b45fc54f/groups/api-owners-id",
		"DELETE /admin/realms/api-monetization/users/3f78ab4c-8a23-4efe-8477-74b8b45fc54f/groups/api-consumers-id",
	}
	if fmt.Sprint(mutations) != fmt.Sprint(want) {
		t.Fatalf("mutations=%v, want %v", mutations, want)
	}
}

func TestOwnerRequestIDValidation(t *testing.T) {
	t.Parallel()
	if !uuidPattern.MatchString("3f78ab4c-8a23-4efe-8477-74b8b45fc54f") {
		t.Fatal("valid UUID was rejected")
	}
	for _, value := range []string{"", "../admin", "3f78ab4c-8a23-4efe-0477-74b8b45fc54f"} {
		if uuidPattern.MatchString(value) {
			t.Fatalf("unsafe request ID %q was accepted", value)
		}
	}
}

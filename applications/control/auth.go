package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

const (
	portalAudience        = "monetization-control"
	portalClientID        = "monetization-portal"
	portalAdminRole       = "monetization-admin"
	portalDeveloperRole   = "monetization-developer"
	portalOwnerRole       = "monetization-owner"
	keycloakNamespace     = "api-monetization-identity"
	keycloakRouteName     = "api-monetization-keycloak"
	keycloakInternalURL   = "http://api-monetization-service.api-monetization-identity.svc.cluster.local:8080"
	keycloakRealm         = "api-monetization"
	identityLookupTimeout = 2 * time.Minute
)

type portalAuthenticator struct {
	externalIssuer string
	verifiers      []*oidc.IDTokenVerifier
}

type portalClaims struct {
	Subject           string `json:"sub"`
	AuthorizedParty   string `json:"azp"`
	Email             string `json:"email"`
	PreferredUsername string `json:"preferred_username"`
	RealmAccess       struct {
		Roles []string `json:"roles"`
	} `json:"realm_access"`
}

type portalClaimsContextKey struct{}

func newPortalAuthenticator(ctx context.Context, kube *kubeClient) (*portalAuthenticator, error) {
	deadline := time.Now().Add(identityLookupTimeout)
	var routeHost string
	var err error
	for time.Now().Before(deadline) {
		routeHost, err = kube.routeHost(ctx, keycloakNamespace, keycloakRouteName)
		if err == nil && routeHost != "" {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if routeHost == "" {
		return nil, fmt.Errorf("discover Keycloak Route: %w", err)
	}

	internalIssuer := keycloakInternalURL + "/realms/" + keycloakRealm
	externalIssuer := "https://" + routeHost + "/realms/" + keycloakRealm
	oidcContext := oidc.ClientContext(ctx, &http.Client{Timeout: 10 * time.Second})
	keySet := oidc.NewRemoteKeySet(oidcContext, internalIssuer+"/protocol/openid-connect/certs")
	config := &oidc.Config{ClientID: portalAudience}

	return &portalAuthenticator{
		externalIssuer: externalIssuer,
		verifiers: []*oidc.IDTokenVerifier{
			oidc.NewVerifier(externalIssuer, keySet, config),
			oidc.NewVerifier(internalIssuer, keySet, config),
		},
	}, nil
}

func (a *portalAuthenticator) requireAdmin(next http.Handler) http.Handler {
	return a.requireRole(portalAdminRole, "monetization administrator role required", next)
}

func (a *portalAuthenticator) requireDeveloper(next http.Handler) http.Handler {
	return a.requireRole(portalDeveloperRole, "monetization developer role required", next)
}

func (a *portalAuthenticator) requireAuthenticated(next http.Handler) http.Handler {
	return a.requireRole("", "", next)
}

func (a *portalAuthenticator) requireRole(role, denial string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rawToken, err := bearerToken(r.Header.Get("Authorization"))
		if err != nil {
			authError(w, http.StatusUnauthorized, "bearer token required")
			return
		}

		var claims portalClaims
		var verifyErr error
		for _, verifier := range a.verifiers {
			var token *oidc.IDToken
			token, verifyErr = verifier.Verify(r.Context(), rawToken)
			if verifyErr == nil {
				verifyErr = token.Claims(&claims)
				break
			}
		}
		if verifyErr != nil {
			slog.Warn("portal bearer token rejected", "error", verifyErr)
			authError(w, http.StatusUnauthorized, "invalid or expired bearer token")
			return
		}
		if role != "" && !contains(claims.RealmAccess.Roles, role) {
			slog.Warn("portal role denied", "user", claims.PreferredUsername, "azp", claims.AuthorizedParty)
			authError(w, http.StatusForbidden, denial)
			return
		}

		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), portalClaimsContextKey{}, claims)))
	})
}

func authenticatedClaims(ctx context.Context) (portalClaims, bool) {
	claims, ok := ctx.Value(portalClaimsContextKey{}).(portalClaims)
	return claims, ok
}

func bearerToken(authorization string) (string, error) {
	fields := strings.Fields(authorization)
	if len(fields) != 2 || !strings.EqualFold(fields[0], "Bearer") || fields[1] == "" {
		return "", errors.New("invalid bearer authorization header")
	}
	return fields[1], nil
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func authError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("WWW-Authenticate", `Bearer realm="api-monetization"`)
	writeJSON(w, status, map[string]string{"error": message})
}

package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const selfServiceIdentityProvider = "keycloak-user"

type productDefinition struct {
	APIProduct string
	Path       string
}

var selfServiceProducts = map[string]productDefinition{
	"ai-chat":   {APIProduct: "ai-chat-api", Path: "/v1/chat/completions"},
	"inventory": {APIProduct: "inventory-api", Path: "/inventory"},
	"payments":  {APIProduct: "payments-api", Path: "/payments"},
}

type developerCustomer struct {
	ID         string
	ExternalID string
	Name       string
	Email      string
}

type apiKeyState struct {
	Approved bool
	Hostname string
}

func (a *app) me(w http.ResponseWriter, r *http.Request) {
	claims, ok := authenticatedClaims(r.Context())
	if !ok {
		authError(w, http.StatusUnauthorized, "authenticated identity required")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"subject":   claims.Subject,
		"username":  claims.PreferredUsername,
		"email":     claims.Email,
		"roles":     claims.RealmAccess.Roles,
		"admin":     contains(claims.RealmAccess.Roles, portalAdminRole),
		"developer": contains(claims.RealmAccess.Roles, portalDeveloperRole),
	})
}

func (a *app) catalog(w http.ResponseWriter, r *http.Request) {
	products, err := a.db.Query(r.Context(), `
		SELECT id, display_name, description, unit_name
		FROM monetization.api_products WHERE active ORDER BY display_name`)
	if err != nil {
		serverError(w, err)
		return
	}
	defer products.Close()
	result := make([]map[string]any, 0)
	for products.Next() {
		var id, name, description, unit string
		if err = products.Scan(&id, &name, &description, &unit); err != nil {
			serverError(w, err)
			return
		}
		_, available := selfServiceProducts[id]
		result = append(result, map[string]any{
			"id": id, "displayName": name, "description": description,
			"unitName": unit, "available": available,
		})
	}
	if err = products.Err(); err != nil {
		serverError(w, err)
		return
	}
	plans, err := a.loadPlans(r.Context())
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"products": result, "plans": plans})
}

func (a *app) loadPlans(ctx context.Context) ([]map[string]any, error) {
	rows, err := a.db.Query(ctx, `
		SELECT id, display_name, monthly_price_cents, included_requests,
		       monthly_quota_requests, overage_micros_per_request,
		       rate_limit_requests, rate_limit_window_seconds
		FROM monetization.plans WHERE active ORDER BY monthly_price_cents NULLS LAST, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	for rows.Next() {
		var id, name string
		var monthly, included, quota *int64
		var overage int64
		var limit, window *int32
		if err = rows.Scan(&id, &name, &monthly, &included, &quota, &overage, &limit, &window); err != nil {
			return nil, err
		}
		result = append(result, map[string]any{
			"id": id, "displayName": name, "monthlyPriceCents": monthly,
			"includedRequests": included, "rateLimitRequests": limit,
			"monthlyQuotaRequests": quota, "overageMicrosPerRequest": overage,
			"rateLimitWindowSeconds": window,
		})
	}
	return result, rows.Err()
}

func (a *app) mySubscriptions(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	if claims.Subject == "" {
		authError(w, http.StatusUnauthorized, "token subject required")
		return
	}
	result, err := a.loadManagedSubscriptionsByIdentity(r.Context(), selfServiceIdentityProvider, claims.Subject, "")
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) myUsage(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusOK, []usageSummary{})
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	usage, err := a.loadUsage(r.Context())
	if err != nil {
		serverError(w, err)
		return
	}
	result := make([]usageSummary, 0, 1)
	for _, item := range usage {
		if item.Customer == customer.ExternalID {
			result = append(result, item)
		}
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) subscribe(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	if claims.Subject == "" {
		authError(w, http.StatusUnauthorized, "token subject required")
		return
	}
	var input struct {
		Product string `json:"product"`
		Plan    string `json:"plan"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must contain product and plan"})
		return
	}
	input.Product = strings.ToLower(strings.TrimSpace(input.Product))
	input.Plan = strings.ToLower(strings.TrimSpace(input.Plan))
	if _, available := selfServiceProducts[input.Product]; !available || !validIdentifier(input.Plan) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "selected API product or plan is not available for self-service"})
		return
	}
	var valid bool
	if err := a.db.QueryRow(r.Context(), `
		SELECT EXISTS(SELECT 1 FROM monetization.plans WHERE id=$1 AND active)`, input.Plan).Scan(&valid); err != nil || !valid {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown or inactive plan"})
		return
	}
	customer, err := a.ensureDeveloperCustomer(r.Context(), claims)
	if err != nil {
		serverError(w, err)
		return
	}
	existing, err := a.loadManagedSubscriptions(r.Context(), customer.ExternalID, input.Product)
	if err != nil {
		serverError(w, err)
		return
	}
	if len(existing) == 1 && existing[0].Status == "suspended" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "subscription is suspended; an administrator must resume or cancel it"})
		return
	}
	if len(existing) == 0 {
		apiKeyName, secretName := selfServiceResourceNames(customer.ExternalID, input.Product)
		if err = a.kube.deleteDeveloperCredential(r.Context(), a.apiKeyNS, apiKeyName, secretName); err != nil {
			serverError(w, fmt.Errorf("remove stale API credential before subscribing: %w", err))
			return
		}
	}
	_, err = a.db.Exec(r.Context(), `
		INSERT INTO monetization.subscriptions (customer_id, api_product_id, plan_id)
		VALUES ($1::uuid, $2, $3)
		ON CONFLICT (customer_id, api_product_id) WHERE status='active' DO NOTHING`,
		customer.ID, input.Product, input.Plan)
	if err != nil {
		serverError(w, err)
		return
	}
	result, err := a.loadSubscriptions(r.Context(), customer.ExternalID, input.Product)
	if err != nil {
		serverError(w, fmt.Errorf("load self-service subscription: %w", err))
		return
	}
	if len(result) != 1 {
		serverError(w, errors.New("self-service subscription was not created"))
		return
	}
	if err = a.provisionDeveloperCredential(r.Context(), customer, result[0]); err != nil {
		serverError(w, fmt.Errorf("provision operator-backed API credential: %w", err))
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, map[string]any{
		"subscription": result[0],
		"credential":   map[string]string{"status": "provisioning"},
	})
}

func (a *app) changeMyPlan(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	product := r.PathValue("product")
	if claims.Subject == "" || !selfServiceProductAvailable(product) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid subscription"})
		return
	}
	var input struct {
		Plan string `json:"plan"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must contain a plan"})
		return
	}
	input.Plan = strings.ToLower(strings.TrimSpace(input.Plan))
	if !validIdentifier(input.Plan) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid plan"})
		return
	}
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer subscription not found"})
		return
	}
	current, err := a.loadSubscriptions(r.Context(), customer.ExternalID, product)
	if err != nil || len(current) != 1 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer subscription not found"})
		return
	}
	var valid bool
	if err = a.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM monetization.plans WHERE id=$1 AND active)`, input.Plan).Scan(&valid); err != nil || !valid {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown or inactive plan"})
		return
	}
	apiKeyName, _ := selfServiceResourceNames(customer.ExternalID, product)
	if err = a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, apiKeyName, input.Plan); err != nil {
		serverError(w, err)
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err == nil {
		_, err = tx.Exec(r.Context(), `
			UPDATE monetization.subscriptions SET plan_id=$1, version=version+1, updated_at=now()
			WHERE id=$2::uuid`, input.Plan, current[0].ID)
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `
			INSERT INTO monetization.plan_changes
			(subscription_id, previous_plan_id, new_plan_id, changed_by, reason)
			VALUES ($1::uuid, $2, $3, $4, 'developer self-service plan change')`,
			current[0].ID, current[0].Plan, input.Plan, claims.PreferredUsername)
	}
	if err == nil {
		err = tx.Commit(r.Context())
	} else if tx != nil {
		_ = tx.Rollback(r.Context())
	}
	if err != nil {
		_ = a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, apiKeyName, current[0].Plan)
		serverError(w, err)
		return
	}
	updated, err := a.loadSubscriptions(r.Context(), customer.ExternalID, product)
	if err != nil {
		serverError(w, err)
		return
	}
	if len(updated) != 1 {
		serverError(w, errors.New("updated self-service subscription was not found"))
		return
	}
	a.upgradeCounter.Add(1)
	writeJSON(w, http.StatusOK, updated[0])
}

func (a *app) cancelMySubscription(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	claims, _ := authenticatedClaims(r.Context())
	customer, subscription, ok := a.developerManagedSubscription(w, r, claims, r.PathValue("product"))
	if !ok {
		return
	}
	var input struct {
		Version int64 `json:"version"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input); err != nil || input.Version < 1 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must contain the current subscription version"})
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		serverError(w, err)
		return
	}
	defer func() { _ = tx.Rollback(r.Context()) }()
	command, err := tx.Exec(r.Context(), `
		UPDATE monetization.subscriptions
		SET status='cancelled', ends_at=now(), version=version+1, updated_at=now()
		WHERE id=$1::uuid AND status IN ('active', 'suspended') AND version=$2`, subscription.ID, input.Version)
	if err != nil {
		serverError(w, err)
		return
	}
	if command.RowsAffected() != 1 {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "subscription changed; refresh before cancelling"})
		return
	}
	_, err = tx.Exec(r.Context(), `
		UPDATE monetization.api_credentials
		SET status='revoked', revoked_at=COALESCE(revoked_at, now()),
		    kubernetes_name=NULL, secret_name=NULL
		WHERE subscription_id=$1::uuid AND status='active'`, subscription.ID)
	if err != nil {
		serverError(w, err)
		return
	}
	_, err = tx.Exec(r.Context(), `
		INSERT INTO monetization.subscription_events
		(subscription_id, event_type, actor, details)
		VALUES ($1::uuid, 'subscription-cancelled', $2,
		        jsonb_build_object('previousStatus', $3::text))`,
		subscription.ID, claims.PreferredUsername, subscription.Status)
	if err != nil {
		serverError(w, err)
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		serverError(w, err)
		return
	}

	apiKeyName, secretName := selfServiceResourceNames(customer.ExternalID, subscription.Product)
	cleanupPending := false
	if err = a.kube.deleteDeveloperCredential(r.Context(), a.apiKeyNS, apiKeyName, secretName); err != nil {
		cleanupPending = true
		slog.Warn("subscription cancelled but credential cleanup is pending",
			"customer", customer.ExternalID, "product", subscription.Product, "error", err)
	}
	status := http.StatusOK
	if cleanupPending {
		status = http.StatusAccepted
	}
	writeJSON(w, status, map[string]any{
		"status": "cancelled", "product": subscription.Product,
		"cleanupPending": cleanupPending,
	})
}

func (a *app) credentialStatus(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	customer, subscription, ok := a.developerSubscription(w, r, claims, r.PathValue("product"))
	if !ok {
		return
	}
	revealed, err := a.credentialWasRevealed(r.Context(), subscription.ID)
	if err != nil {
		serverError(w, err)
		return
	}
	apiKeyName, _ := selfServiceResourceNames(customer.ExternalID, subscription.Product)
	state, err := a.kube.apiKeyState(r.Context(), a.apiKeyNS, apiKeyName)
	if err != nil {
		var apiErr *kubeAPIError
		if errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusNotFound {
			writeJSON(w, http.StatusOK, map[string]any{"status": "provisioning", "revealed": false})
			return
		}
		serverError(w, err)
		return
	}
	status := "provisioning"
	if state.Approved {
		status = "ready"
	} else if recovered, recoveryErr := a.kube.ensureAutomaticAPIKeyApproval(r.Context(), a.apiKeyNS, apiKeyName); recoveryErr != nil {
		slog.Warn("failed to recover automatic API key approval",
			"customer", customer.ExternalID, "product", subscription.Product, "error", recoveryErr)
	} else if recovered {
		slog.Info("recovered automatic API key approval",
			"customer", customer.ExternalID, "product", subscription.Product)
	}
	if state.Approved && revealed {
		status = "active"
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status, "revealed": revealed, "endpoint": endpointFor(state.Hostname, subscription.Product)})
}

func (a *app) revealCredential(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	claims, _ := authenticatedClaims(r.Context())
	customer, subscription, ok := a.developerSubscription(w, r, claims, r.PathValue("product"))
	if !ok {
		return
	}
	revealed, err := a.credentialWasRevealed(r.Context(), subscription.ID)
	if err != nil {
		serverError(w, err)
		return
	}
	if revealed {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "API key was already revealed; rotate it to obtain a new value"})
		return
	}
	apiKeyName, secretName := selfServiceResourceNames(customer.ExternalID, subscription.Product)
	state, err := a.kube.apiKeyState(r.Context(), a.apiKeyNS, apiKeyName)
	if err != nil || !state.Approved {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "API key is still being provisioned"})
		return
	}
	apiKey, err := a.kube.secretValue(r.Context(), a.apiKeyNS, secretName, "api_key")
	if err != nil {
		serverError(w, err)
		return
	}
	digestBytes := sha256.Sum256([]byte(apiKey))
	digest := hex.EncodeToString(digestBytes[:])
	prefix := apiKey
	if len(prefix) > 12 {
		prefix = prefix[:12]
	}
	var credentialID string
	err = a.db.QueryRow(r.Context(), `
		INSERT INTO monetization.api_credentials
		(subscription_id, key_prefix, key_digest, digest_algorithm, kubernetes_name, secret_name, revealed_at)
		VALUES ($1::uuid, $2, $3, 'sha256', $4, $5, now())
		ON CONFLICT (key_digest) DO NOTHING
		RETURNING id::text`, subscription.ID, prefix, digest, apiKeyName, secretName).Scan(&credentialID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "API key was already revealed"})
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "active", "revealed": true, "apiKey": apiKey,
		"prefix": prefix, "endpoint": endpointFor(state.Hostname, subscription.Product),
	})
}

func (a *app) rotateCredential(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	claims, _ := authenticatedClaims(r.Context())
	customer, subscription, ok := a.developerSubscription(w, r, claims, r.PathValue("product"))
	if !ok {
		return
	}
	apiKeyName, secretName := selfServiceResourceNames(customer.ExternalID, subscription.Product)
	if err := a.kube.deleteDeveloperCredential(r.Context(), a.apiKeyNS, apiKeyName, secretName); err != nil {
		serverError(w, fmt.Errorf("remove previous API credential: %w", err))
		return
	}
	if _, err := a.db.Exec(r.Context(), `
		UPDATE monetization.api_credentials
		SET status='revoked', revoked_at=now(), kubernetes_name=NULL, secret_name=NULL
		WHERE subscription_id=$1::uuid AND status='active'`, subscription.ID); err != nil {
		serverError(w, fmt.Errorf("revoke previous API credential: %w", err))
		return
	}
	if err := a.provisionDeveloperCredential(r.Context(), customer, subscription); err != nil {
		serverError(w, fmt.Errorf("provision rotated API credential: %w", err))
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"status": "provisioning", "revealed": false,
	})
}

func (a *app) developerSubscription(w http.ResponseWriter, r *http.Request, claims portalClaims, product string) (developerCustomer, subscription, bool) {
	return a.developerSubscriptionByState(w, r, claims, product, false)
}

func (a *app) developerManagedSubscription(w http.ResponseWriter, r *http.Request, claims portalClaims, product string) (developerCustomer, subscription, bool) {
	return a.developerSubscriptionByState(w, r, claims, product, true)
}

func (a *app) developerSubscriptionByState(w http.ResponseWriter, r *http.Request, claims portalClaims, product string, includeSuspended bool) (developerCustomer, subscription, bool) {
	if claims.Subject == "" || !selfServiceProductAvailable(product) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid developer subscription"})
		return developerCustomer{}, subscription{}, false
	}
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer subscription not found"})
		return developerCustomer{}, subscription{}, false
	}
	var items []subscription
	if includeSuspended {
		items, err = a.loadManagedSubscriptions(r.Context(), customer.ExternalID, product)
	} else {
		items, err = a.loadSubscriptions(r.Context(), customer.ExternalID, product)
	}
	if err != nil || len(items) != 1 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer subscription not found"})
		return developerCustomer{}, subscription{}, false
	}
	return customer, items[0], true
}

func (a *app) ensureDeveloperCustomer(ctx context.Context, claims portalClaims) (developerCustomer, error) {
	if existing, err := a.developerCustomer(ctx, claims.Subject); err == nil {
		return existing, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return developerCustomer{}, err
	}
	externalID := selfServiceCustomerID(claims.Subject)
	displayName := strings.TrimSpace(claims.PreferredUsername)
	if displayName == "" {
		displayName = strings.TrimSpace(claims.Email)
	}
	if displayName == "" {
		displayName = "API Developer"
	}
	if claims.Email == "" {
		claims.Email = externalID + "@example.invalid"
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return developerCustomer{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var customerID string
	err = tx.QueryRow(ctx, `
		INSERT INTO monetization.customers (external_id, display_name, billing_email)
		VALUES ($1, $2, NULLIF($3, ''))
		ON CONFLICT (external_id) DO UPDATE SET
		  display_name=EXCLUDED.display_name, billing_email=EXCLUDED.billing_email, updated_at=now()
		RETURNING id::text`, externalID, displayName, claims.Email).Scan(&customerID)
	if err != nil {
		return developerCustomer{}, err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO monetization.subscription_identities (customer_id, provider, subject)
		VALUES ($1::uuid, $2, $3)
		ON CONFLICT (provider, subject) DO NOTHING`, customerID, selfServiceIdentityProvider, claims.Subject)
	if err != nil {
		return developerCustomer{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return developerCustomer{}, err
	}
	return a.developerCustomer(ctx, claims.Subject)
}

func (a *app) developerCustomer(ctx context.Context, subject string) (developerCustomer, error) {
	var result developerCustomer
	err := a.db.QueryRow(ctx, `
		SELECT c.id::text, c.external_id, c.display_name, COALESCE(c.billing_email, '')
		FROM monetization.subscription_identities i
		JOIN monetization.customers c ON c.id=i.customer_id
		WHERE i.provider=$1 AND i.subject=$2 AND i.status='active' AND c.status='active'`,
		selfServiceIdentityProvider, subject).Scan(&result.ID, &result.ExternalID, &result.Name, &result.Email)
	return result, err
}

func (a *app) credentialWasRevealed(ctx context.Context, subscriptionID string) (bool, error) {
	var revealed bool
	err := a.db.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM monetization.api_credentials
		WHERE subscription_id=$1::uuid AND status='active' AND revealed_at IS NOT NULL)`, subscriptionID).Scan(&revealed)
	return revealed, err
}

func selfServiceCustomerID(subject string) string {
	digest := sha256.Sum256([]byte(keycloakRealm + ":" + subject))
	return "dev-" + hex.EncodeToString(digest[:12])
}

func selfServiceResourceNames(customer, product string) (string, string) {
	base := customer + "-" + product
	return base, base + "-key"
}

func selfServiceProductAvailable(product string) bool {
	_, available := selfServiceProducts[product]
	return available
}

func endpointFor(hostname, product string) string {
	if hostname == "" {
		return ""
	}
	definition, available := selfServiceProducts[product]
	if !available {
		return ""
	}
	return "https://" + hostname + definition.Path
}

func (a *app) provisionDeveloperCredential(ctx context.Context, customer developerCustomer, item subscription) error {
	apiKeyName, secretName := selfServiceResourceNames(customer.ExternalID, item.Product)
	generatorName := apiKeyName + "-generator"
	labels := map[string]string{
		"app.kubernetes.io/part-of":           "api-monetization",
		"app.kubernetes.io/managed-by":        "monetization-control",
		"monetization.arencloud.com/customer": customer.ExternalID,
	}
	password := map[string]any{
		"apiVersion": "generators.external-secrets.io/v1alpha1", "kind": "Password",
		"metadata": map[string]any{"name": generatorName, "namespace": a.apiKeyNS, "labels": labels},
		"spec":     map[string]any{"length": 48, "digits": 8, "symbols": 0, "allowRepeat": true, "noUpper": false, "secretKeys": []string{"api_key"}},
	}
	externalSecret := map[string]any{
		"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret",
		"metadata": map[string]any{"name": secretName, "namespace": a.apiKeyNS, "labels": labels},
		"spec": map[string]any{
			"refreshPolicy": "CreatedOnce",
			"target":        map[string]any{"name": secretName, "creationPolicy": "Owner", "immutable": true},
			"dataFrom": []any{map[string]any{"sourceRef": map[string]any{"generatorRef": map[string]any{
				"apiVersion": "generators.external-secrets.io/v1alpha1", "kind": "Password", "name": generatorName,
			}}}},
		},
	}
	definition, available := selfServiceProducts[item.Product]
	if !available {
		return fmt.Errorf("API product %q is not enabled for self-service", item.Product)
	}
	apiKey := map[string]any{
		"apiVersion": "devportal.kuadrant.io/v1alpha1", "kind": "APIKey",
		"metadata": map[string]any{"name": apiKeyName, "namespace": a.apiKeyNS, "labels": labels},
		"spec": map[string]any{
			"apiProductRef": map[string]string{"name": definition.APIProduct},
			"planTier":      item.Plan,
			"requestedBy":   map[string]string{"userId": customer.ExternalID, "email": customer.Email},
			"secretRef":     map[string]string{"name": secretName},
			"useCase":       "Developer portal self-service subscription",
		},
	}
	for _, resource := range []struct {
		path string
		body map[string]any
	}{
		{fmt.Sprintf("/apis/generators.external-secrets.io/v1alpha1/namespaces/%s/passwords", a.apiKeyNS), password},
		{fmt.Sprintf("/apis/external-secrets.io/v1/namespaces/%s/externalsecrets", a.apiKeyNS), externalSecret},
	} {
		if err := a.kube.createIfAbsent(ctx, resource.path, resource.body); err != nil {
			return err
		}
	}
	if err := a.kube.waitForSecret(ctx, a.apiKeyNS, secretName, 30*time.Second); err != nil {
		return err
	}
	return a.kube.createIfAbsent(ctx,
		fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeys", a.apiKeyNS), apiKey)
}

func (k *kubeClient) createIfAbsent(ctx context.Context, path string, body any) error {
	err := k.request(ctx, http.MethodPost, path, body, nil)
	var apiErr *kubeAPIError
	if errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusConflict {
		return nil
	}
	return err
}

func (k *kubeClient) deleteDeveloperCredential(ctx context.Context, namespace, apiKeyName, secretName string) error {
	generatorName := apiKeyName + "-generator"
	apiKeyPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeys/%s", namespace, apiKeyName)
	if err := k.deleteIfExists(ctx, apiKeyPath); err != nil {
		return err
	}
	if err := k.waitForDeletion(ctx, []string{apiKeyPath}, 30*time.Second); err != nil {
		return err
	}

	portalPaths, err := k.apiKeyRequestArtifactPaths(ctx, namespace, apiKeyName)
	if err != nil {
		return err
	}
	paths := append(portalPaths,
		fmt.Sprintf("/apis/external-secrets.io/v1/namespaces/%s/externalsecrets/%s", namespace, secretName),
		fmt.Sprintf("/api/v1/namespaces/%s/secrets/%s", namespace, secretName),
		fmt.Sprintf("/apis/generators.external-secrets.io/v1alpha1/namespaces/%s/passwords/%s", namespace, generatorName),
	)
	for _, path := range paths {
		if err := k.deleteIfExists(ctx, path); err != nil {
			return err
		}
	}
	return k.waitForDeletion(ctx, paths, 30*time.Second)
}

func (k *kubeClient) apiKeyRequestArtifactPaths(ctx context.Context, namespace, apiKeyName string) ([]string, error) {
	var requests struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Spec struct {
				APIKeyRef struct {
					Name      string `json:"name"`
					Namespace string `json:"namespace"`
				} `json:"apiKeyRef"`
			} `json:"spec"`
		} `json:"items"`
	}
	requestListPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeyrequests", namespace)
	if err := k.request(ctx, http.MethodGet, requestListPath, nil, &requests); err != nil {
		return nil, err
	}
	requestNames := make(map[string]struct{})
	for _, item := range requests.Items {
		if item.Spec.APIKeyRef.Name == apiKeyName && item.Spec.APIKeyRef.Namespace == namespace {
			requestNames[item.Metadata.Name] = struct{}{}
		}
	}

	var approvals struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Spec struct {
				APIKeyRequestRef struct {
					Name string `json:"name"`
				} `json:"apiKeyRequestRef"`
			} `json:"spec"`
		} `json:"items"`
	}
	approvalListPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeyapprovals", namespace)
	if err := k.request(ctx, http.MethodGet, approvalListPath, nil, &approvals); err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(requestNames)*2)
	for _, item := range approvals.Items {
		if _, matches := requestNames[item.Spec.APIKeyRequestRef.Name]; matches {
			paths = append(paths, approvalListPath+"/"+item.Metadata.Name)
		}
	}
	for requestName := range requestNames {
		paths = append(paths, requestListPath+"/"+requestName)
	}
	return paths, nil
}

// ensureAutomaticAPIKeyApproval recovers from a race in which the Developer
// Portal auto-approval reconciler observes an APIKeyRequest before its status is
// initialized. It submits the missing approval only after independently checking
// that the referenced APIProduct is configured for automatic approval. RHCL
// validates the approval and remains responsible for credential enforcement.
func (k *kubeClient) ensureAutomaticAPIKeyApproval(ctx context.Context, namespace, apiKeyName string) (bool, error) {
	var requests struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Spec struct {
				APIKeyRef struct {
					Name      string `json:"name"`
					Namespace string `json:"namespace"`
				} `json:"apiKeyRef"`
				APIProductRef struct {
					Name string `json:"name"`
				} `json:"apiProductRef"`
			} `json:"spec"`
			Status struct {
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}
	listPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeyrequests", namespace)
	if err := k.request(ctx, http.MethodGet, listPath, nil, &requests); err != nil {
		return false, err
	}
	for _, item := range requests.Items {
		if item.Spec.APIKeyRef.Name != apiKeyName || item.Spec.APIKeyRef.Namespace != namespace {
			continue
		}
		approved := false
		for _, condition := range item.Status.Conditions {
			if condition.Type == "Approved" && condition.Status == "True" {
				approved = true
			}
		}
		if approved {
			continue
		}
		var product struct {
			Spec struct {
				ApprovalMode string `json:"approvalMode"`
			} `json:"spec"`
		}
		productPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apiproducts/%s", namespace, item.Spec.APIProductRef.Name)
		if err := k.request(ctx, http.MethodGet, productPath, nil, &product); err != nil {
			return false, err
		}
		if product.Spec.ApprovalMode != "automatic" {
			return false, nil
		}
		approval := map[string]any{
			"apiVersion": "devportal.kuadrant.io/v1alpha1", "kind": "APIKeyApproval",
			"metadata": map[string]any{"name": item.Metadata.Name + "-portal-auto", "namespace": namespace},
			"spec": map[string]any{
				"apiKeyRequestRef": map[string]string{"name": item.Metadata.Name},
				"approved":         true, "reason": "PortalAutomaticApproval",
				"message":    "Recovered automatic approval for a self-service subscription",
				"reviewedAt": time.Now().UTC().Format(time.RFC3339Nano), "reviewedBy": "monetization-control",
			},
		}
		approvalPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeyapprovals", namespace)
		if err := k.createIfAbsent(ctx, approvalPath, approval); err != nil {
			return false, err
		}
		return true, nil
	}
	return false, nil
}

func (k *kubeClient) waitForDeletion(ctx context.Context, paths []string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		pending := false
		for _, path := range paths {
			err := k.request(ctx, http.MethodGet, path, nil, nil)
			var apiErr *kubeAPIError
			if errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusNotFound {
				continue
			}
			if err != nil {
				return err
			}
			pending = true
		}
		if !pending {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %d operator-managed credential resources to be deleted", len(paths))
}

func (k *kubeClient) deleteIfExists(ctx context.Context, path string) error {
	err := k.request(ctx, http.MethodDelete, path, nil, nil)
	var apiErr *kubeAPIError
	if errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusNotFound {
		return nil
	}
	return err
}

func (k *kubeClient) apiKeyState(ctx context.Context, namespace, name string) (apiKeyState, error) {
	var resource struct {
		Status struct {
			APIHostname string `json:"apiHostname"`
			Conditions  []struct {
				Type   string `json:"type"`
				Status string `json:"status"`
			} `json:"conditions"`
		} `json:"status"`
	}
	path := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeys/%s", namespace, name)
	if err := k.request(ctx, http.MethodGet, path, nil, &resource); err != nil {
		return apiKeyState{}, err
	}
	result := apiKeyState{Hostname: resource.Status.APIHostname}
	for _, condition := range resource.Status.Conditions {
		if condition.Type == "Approved" && condition.Status == "True" {
			result.Approved = true
		}
	}
	return result, nil
}

func (k *kubeClient) secretValue(ctx context.Context, namespace, name, key string) (string, error) {
	var secret struct {
		Data map[string]string `json:"data"`
	}
	path := fmt.Sprintf("/api/v1/namespaces/%s/secrets/%s", namespace, name)
	if err := k.request(ctx, http.MethodGet, path, nil, &secret); err != nil {
		return "", err
	}
	encoded := secret.Data[key]
	if encoded == "" {
		return "", fmt.Errorf("secret %s/%s does not contain %s", namespace, name, key)
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", err
	}
	return string(decoded), nil
}

func (k *kubeClient) waitForSecret(ctx context.Context, namespace, name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		_, lastErr = k.secretValue(ctx, namespace, name, "api_key")
		if lastErr == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("generated API key Secret %s/%s was not ready: %w", namespace, name, lastErr)
}

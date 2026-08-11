package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const selfServiceIdentityProvider = "keycloak-user"

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
		result = append(result, map[string]any{
			"id": id, "displayName": name, "description": description,
			"unitName": unit, "available": id == "inventory",
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
		       rate_limit_requests, rate_limit_window_seconds
		FROM monetization.plans WHERE active ORDER BY monthly_price_cents NULLS LAST`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	for rows.Next() {
		var id, name string
		var monthly, included *int64
		var limit, window *int32
		if err = rows.Scan(&id, &name, &monthly, &included, &limit, &window); err != nil {
			return nil, err
		}
		result = append(result, map[string]any{
			"id": id, "displayName": name, "monthlyPriceCents": monthly,
			"includedRequests": included, "rateLimitRequests": limit,
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
	result, err := a.loadSubscriptionsByIdentity(r.Context(), selfServiceIdentityProvider, claims.Subject, "")
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
	if input.Product != "inventory" || !validIdentifier(input.Plan) {
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
	if claims.Subject == "" || product != "inventory" {
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
	if revealed {
		writeJSON(w, http.StatusOK, map[string]any{"status": "active", "revealed": true})
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
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status, "revealed": false, "endpoint": endpointFor(state.Hostname)})
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
		"prefix": prefix, "endpoint": endpointFor(state.Hostname),
	})
}

func (a *app) developerSubscription(w http.ResponseWriter, r *http.Request, claims portalClaims, product string) (developerCustomer, subscription, bool) {
	if claims.Subject == "" || product != "inventory" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid developer subscription"})
		return developerCustomer{}, subscription{}, false
	}
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer subscription not found"})
		return developerCustomer{}, subscription{}, false
	}
	items, err := a.loadSubscriptions(r.Context(), customer.ExternalID, product)
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

func endpointFor(hostname string) string {
	if hostname == "" {
		return ""
	}
	return "https://" + hostname + "/inventory"
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
	apiKey := map[string]any{
		"apiVersion": "devportal.kuadrant.io/v1alpha1", "kind": "APIKey",
		"metadata": map[string]any{"name": apiKeyName, "namespace": a.apiKeyNS, "labels": labels},
		"spec": map[string]any{
			"apiProductRef": map[string]string{"name": "inventory-api"},
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

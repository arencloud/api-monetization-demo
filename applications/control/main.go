package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/arencloud/api-monetization-demo/internal/telemetry"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed web/*
var web embed.FS

type app struct {
	db             *pgxpool.Pool
	kube           *kubeClient
	auth           *portalAuthenticator
	apiKeyName     string
	apiKeyNS       string
	upgradeCounter atomic.Uint64
}

type subscription struct {
	ID             string     `json:"id"`
	CustomerID     string     `json:"customerId"`
	Customer       string     `json:"customer"`
	Product        string     `json:"product"`
	Plan           string     `json:"plan"`
	PlanName       string     `json:"planName"`
	MonthlyCents   *int64     `json:"monthlyPriceCents"`
	Included       *int64     `json:"includedRequests"`
	MonthlyQuota   *int64     `json:"monthlyQuotaRequests"`
	OverageMicros  int64      `json:"overageMicrosPerRequest"`
	RateLimit      *int32     `json:"rateLimitRequests"`
	RateWindowSecs *int32     `json:"rateLimitWindowSeconds"`
	Version        int64      `json:"version"`
	Status         string     `json:"status"`
	StartsAt       time.Time  `json:"startsAt"`
	EndsAt         *time.Time `json:"endsAt,omitempty"`
}

func main() {
	ctx := context.Background()
	databaseURL := requiredEnv("DATABASE_URL")
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		fatal("invalid database configuration", err)
	}
	defer pool.Close()
	if err = waitForDatabase(ctx, pool, 2*time.Minute); err != nil {
		fatal("database did not become ready", err)
	}
	if err = applyDatabaseMigrations(ctx, pool); err != nil {
		fatal("database migration failed", err)
	}
	kube, err := newKubeClient()
	if err != nil {
		fatal("Kubernetes client configuration failed", err)
	}
	auth, err := newPortalAuthenticator(ctx, kube)
	if err != nil {
		fatal("portal identity configuration failed", err)
	}
	application := &app{
		db:         pool,
		kube:       kube,
		auth:       auth,
		apiKeyName: env("DEMO_APIKEY_NAME", "demo-inventory-key"),
		apiKeyNS:   env("DEMO_APIKEY_NAMESPACE", "api-monetization-apps"),
	}
	recorder := telemetry.New("monetization-control")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", application.index)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", application.ready)
	mux.HandleFunc("GET /api/config", application.portalConfig)
	mux.Handle("GET /api/me", auth.requireAuthenticated(http.HandlerFunc(application.me)))
	mux.Handle("GET /api/catalog", auth.requireAuthenticated(http.HandlerFunc(application.catalog)))
	mux.Handle("GET /api/me/subscriptions", auth.requireDeveloper(http.HandlerFunc(application.mySubscriptions)))
	mux.Handle("GET /api/me/usage", auth.requireDeveloper(http.HandlerFunc(application.myUsage)))
	mux.Handle("GET /api/me/billing", auth.requireDeveloper(http.HandlerFunc(application.myBilling)))
	mux.Handle("POST /api/me/invoices/draft", auth.requireDeveloper(http.HandlerFunc(application.createMyDraftInvoice)))
	mux.Handle("GET /api/me/audit", auth.requireDeveloper(http.HandlerFunc(application.myAudit)))
	mux.Handle("POST /api/me/subscriptions", auth.requireDeveloper(http.HandlerFunc(application.subscribe)))
	mux.Handle("POST /api/me/subscriptions/{product}/plan", auth.requireDeveloper(http.HandlerFunc(application.changeMyPlan)))
	mux.Handle("POST /api/me/subscriptions/{product}/cancel", auth.requireDeveloper(http.HandlerFunc(application.cancelMySubscription)))
	mux.Handle("GET /api/me/credentials/{product}/status", auth.requireDeveloper(http.HandlerFunc(application.credentialStatus)))
	mux.Handle("POST /api/me/credentials/{product}/reveal", auth.requireDeveloper(http.HandlerFunc(application.revealCredential)))
	mux.Handle("POST /api/me/credentials/{product}/rotate", auth.requireDeveloper(http.HandlerFunc(application.rotateCredential)))
	mux.Handle("GET /api/plans", auth.requireAdmin(http.HandlerFunc(application.plans)))
	mux.Handle("GET /api/subscriptions", auth.requireAdmin(http.HandlerFunc(application.subscriptions)))
	mux.Handle("GET /api/usage", auth.requireAdmin(http.HandlerFunc(application.usage)))
	mux.Handle("GET /api/invoices", auth.requireAdmin(http.HandlerFunc(application.invoices)))
	mux.Handle("POST /api/subscriptions/{customer}/invoices/draft", auth.requireAdmin(http.HandlerFunc(application.createCustomerDraftInvoice)))
	mux.Handle("POST /api/subscriptions/{customer}/plan", auth.requireAdmin(http.HandlerFunc(application.changePlan)))
	mux.Handle("POST /api/subscriptions/{customer}/status", auth.requireAdmin(http.HandlerFunc(application.changeSubscriptionStatus)))
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, r *http.Request) {
		recorder.Handler(w, r)
		fmt.Fprintf(w, "# HELP monetization_plan_upgrades_total Successful live plan changes.\n")
		fmt.Fprintf(w, "# TYPE monetization_plan_upgrades_total counter\n")
		fmt.Fprintf(w, "monetization_plan_upgrades_total %d\n", application.upgradeCounter.Load())
		application.businessMetrics(w, r)
	})
	server := &http.Server{
		Addr:              env("HTTP_ADDR", ":8080"),
		Handler:           recorder.Middleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      45 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	internalMux := http.NewServeMux()
	internalMux.HandleFunc("GET /internal/entitlements/{customer}/{product}", application.entitlement)
	internalMux.HandleFunc("GET /internal/entitlements/identity/{provider}/{subject}/{product}", application.entitlementByIdentity)
	internalMux.HandleFunc("GET /internal/entitlements/token/{subject}/{client}/{product}", application.entitlementByToken)
	internalMux.HandleFunc("POST /internal/usage", application.recordUsage)
	internalServer := &http.Server{
		Addr:              env("INTERNAL_HTTP_ADDR", ":8081"),
		Handler:           recorder.Middleware(internalMux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	serverErrors := make(chan error, 2)
	go func() {
		slog.Info("monetization internal API listening", "address", internalServer.Addr)
		serverErrors <- internalServer.ListenAndServe()
	}()
	go func() {
		slog.Info("monetization portal listening", "address", server.Addr)
		serverErrors <- server.ListenAndServe()
	}()
	if err = <-serverErrors; err != nil && !errors.Is(err, http.ErrServerClosed) {
		fatal("HTTP server stopped", err)
	}
}

func (a *app) index(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" && r.URL.Path != "/auth/callback" {
		http.NotFound(w, r)
		return
	}
	content, err := web.ReadFile("web/index.html")
	if err != nil {
		http.Error(w, "UI unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' https:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self' https:")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(content)
}

func (a *app) portalConfig(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]string{
		"clientId":  portalClientID,
		"issuerUrl": a.auth.externalIssuer,
	})
}

func (a *app) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.db.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *app) plans(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `
		SELECT id, display_name, monthly_price_cents, included_requests,
		       monthly_quota_requests, overage_micros_per_request,
		       rate_limit_requests, rate_limit_window_seconds
		FROM monetization.plans WHERE active ORDER BY monthly_price_cents NULLS LAST, id`)
	if err != nil {
		serverError(w, err)
		return
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	for rows.Next() {
		var id, name string
		var monthly, included, quota *int64
		var overage int64
		var limit, window *int32
		if err = rows.Scan(&id, &name, &monthly, &included, &quota, &overage, &limit, &window); err != nil {
			serverError(w, err)
			return
		}
		result = append(result, map[string]any{"id": id, "displayName": name, "monthlyPriceCents": monthly, "includedRequests": included, "monthlyQuotaRequests": quota, "overageMicrosPerRequest": overage, "rateLimitRequests": limit, "rateLimitWindowSeconds": window})
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) subscriptions(w http.ResponseWriter, r *http.Request) {
	result, err := a.loadManagedSubscriptions(r.Context(), "", "")
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) entitlement(w http.ResponseWriter, r *http.Request) {
	customer := r.PathValue("customer")
	product := r.PathValue("product")
	if !validIdentifier(customer) || !validIdentifier(product) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid entitlement identifier"})
		return
	}
	result, err := a.loadSubscriptions(r.Context(), customer, product)
	if err != nil {
		serverError(w, err)
		return
	}
	if len(result) != 1 {
		writeJSON(w, http.StatusOK, map[string]string{"status": "inactive"})
		return
	}
	writeJSON(w, http.StatusOK, result[0])
}

func (a *app) entitlementByIdentity(w http.ResponseWriter, r *http.Request) {
	provider := r.PathValue("provider")
	subject := r.PathValue("subject")
	product := r.PathValue("product")
	if !validIdentifier(provider) || !validIdentifier(subject) || !validIdentifier(product) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid subscription identity"})
		return
	}
	result, err := a.loadSubscriptionsByIdentity(r.Context(), provider, subject, product)
	if err != nil {
		serverError(w, err)
		return
	}
	if len(result) != 1 {
		writeJSON(w, http.StatusOK, map[string]string{"status": "inactive"})
		return
	}
	writeJSON(w, http.StatusOK, result[0])
}

func (a *app) entitlementByToken(w http.ResponseWriter, r *http.Request) {
	subject := r.PathValue("subject")
	client := r.PathValue("client")
	product := r.PathValue("product")
	if !validIdentifier(subject) || !validIdentifier(client) || !validIdentifier(product) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid token identity"})
		return
	}

	// Interactive portal tokens belong to a Keycloak user; client-credentials
	// tokens belong to a Keycloak client. Both resolve to the same commercial
	// subscription without embedding plan state in the JWT.
	result, err := a.loadSubscriptionsByIdentity(r.Context(), selfServiceIdentityProvider, subject, product)
	if err == nil && len(result) == 0 {
		result, err = a.loadSubscriptionsByIdentity(r.Context(), "keycloak-client", client, product)
	}
	if err != nil {
		serverError(w, err)
		return
	}
	if len(result) != 1 {
		writeJSON(w, http.StatusOK, map[string]string{"status": "inactive"})
		return
	}
	writeJSON(w, http.StatusOK, result[0])
}

type usageSummary struct {
	Customer             string  `json:"customer"`
	Product              string  `json:"product"`
	Plan                 string  `json:"plan"`
	Requests             int64   `json:"requests"`
	IncludedRequests     *int64  `json:"includedRequests"`
	OverageRequests      int64   `json:"overageRequests"`
	ProjectedRevenueEuro float64 `json:"projectedRevenueEuro"`
	PeriodStart          string  `json:"periodStart"`
	PeriodEnd            string  `json:"periodEnd"`
}

func (a *app) usage(w http.ResponseWriter, r *http.Request) {
	result, err := a.loadUsage(r.Context())
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) loadUsage(ctx context.Context) ([]usageSummary, error) {
	start, end := currentBillingPeriod(time.Now())
	rows, err := a.db.Query(ctx, `
		SELECT c.external_id, s.api_product_id, s.plan_id,
		       COALESCE(SUM(u.billable_units), 0)::bigint,
		       p.included_requests,
		       GREATEST(COALESCE(SUM(u.billable_units), 0)::bigint
		         - COALESCE(p.included_requests, COALESCE(SUM(u.billable_units), 0)::bigint), 0),
		       ((COALESCE(p.monthly_price_cents, 0)::numeric / 100)
		       + (GREATEST(COALESCE(SUM(u.billable_units), 0)::bigint
		            - COALESCE(p.included_requests, COALESCE(SUM(u.billable_units), 0)::bigint), 0)
		          * p.overage_micros_per_request::numeric / 1000000))::double precision
		FROM monetization.subscriptions s
		JOIN monetization.customers c ON c.id=s.customer_id
		JOIN monetization.plans p ON p.id=s.plan_id
		LEFT JOIN monetization.usage_events u ON u.subscription_id=s.id
		  AND u.occurred_at >= $1 AND u.occurred_at < $2
		WHERE s.status='active'
		GROUP BY c.external_id, s.api_product_id, s.plan_id, p.included_requests,
		         p.monthly_price_cents, p.overage_micros_per_request
		ORDER BY c.external_id, s.api_product_id`, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]usageSummary, 0)
	for rows.Next() {
		var item usageSummary
		if err = rows.Scan(&item.Customer, &item.Product, &item.Plan, &item.Requests, &item.IncludedRequests, &item.OverageRequests, &item.ProjectedRevenueEuro); err != nil {
			return nil, err
		}
		item.PeriodStart = start.Format(time.DateOnly)
		item.PeriodEnd = end.Format(time.DateOnly)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (a *app) recordUsage(w http.ResponseWriter, r *http.Request) {
	var event struct {
		RequestID     string    `json:"requestId"`
		Customer      string    `json:"customer"`
		Product       string    `json:"product"`
		Operation     string    `json:"operation"`
		OccurredAt    time.Time `json:"occurredAt"`
		StatusCode    int       `json:"statusCode"`
		DurationMS    float64   `json:"durationMs"`
		ResponseBytes int64     `json:"responseBytes"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32*1024)).Decode(&event); err != nil || event.RequestID == "" || event.Customer == "" || event.Product == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid usage event"})
		return
	}
	command, err := a.db.Exec(r.Context(), `
		INSERT INTO monetization.usage_events
		(request_id, subscription_id, api_product_id, operation, occurred_at,
		 status_code, duration_ms, response_bytes)
		SELECT $1, s.id, s.api_product_id, $4, $5, $6, $7, $8
		FROM monetization.subscriptions s
		JOIN monetization.customers c ON c.id=s.customer_id
		WHERE c.external_id=$2 AND s.api_product_id=$3 AND s.status='active'
		ON CONFLICT (request_id) DO NOTHING`,
		event.RequestID, event.Customer, event.Product, event.Operation,
		event.OccurredAt, event.StatusCode, event.DurationMS, event.ResponseBytes)
	if err != nil {
		serverError(w, err)
		return
	}
	if command.RowsAffected() == 0 {
		writeJSON(w, http.StatusAccepted, map[string]string{"status": "duplicate or unknown subscription"})
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (a *app) businessMetrics(w http.ResponseWriter, r *http.Request) {
	usage, err := a.loadUsage(r.Context())
	if err != nil {
		slog.Warn("business metrics query failed", "error", err)
		return
	}
	fmt.Fprintln(w, "# HELP monetization_billable_requests Stored accepted requests by customer and plan.")
	fmt.Fprintln(w, "# TYPE monetization_billable_requests gauge")
	fmt.Fprintln(w, "# HELP monetization_projected_revenue_euros Projected monthly base and overage revenue.")
	fmt.Fprintln(w, "# TYPE monetization_projected_revenue_euros gauge")
	for _, item := range usage {
		fmt.Fprintf(w, "monetization_billable_requests{customer=%q,product=%q,plan=%q} %d\n", item.Customer, item.Product, item.Plan, item.Requests)
		fmt.Fprintf(w, "monetization_projected_revenue_euros{customer=%q,product=%q,plan=%q} %.6f\n", item.Customer, item.Product, item.Plan, item.ProjectedRevenueEuro)
	}
}

func (a *app) loadSubscriptions(ctx context.Context, customer, product string) ([]subscription, error) {
	return a.loadSubscriptionsByState(ctx, customer, product, false)
}

func (a *app) loadManagedSubscriptions(ctx context.Context, customer, product string) ([]subscription, error) {
	return a.loadSubscriptionsByState(ctx, customer, product, true)
}

func (a *app) loadSubscriptionsByState(ctx context.Context, customer, product string, includeSuspended bool) ([]subscription, error) {
	query := `
		SELECT s.id::text, c.external_id, c.display_name, p.id, s.plan_id,
		       pl.display_name, pl.monthly_price_cents, pl.included_requests,
		       pl.monthly_quota_requests, pl.overage_micros_per_request,
		       pl.rate_limit_requests,
		       pl.rate_limit_window_seconds, s.version,
		       s.status, s.starts_at, s.ends_at
		FROM monetization.subscriptions s
		JOIN monetization.customers c ON c.id = s.customer_id
		JOIN monetization.api_products p ON p.id = s.api_product_id
		JOIN monetization.plans pl ON pl.id = s.plan_id
		WHERE s.status = 'active'`
	if includeSuspended {
		query = strings.Replace(query, "WHERE s.status = 'active'", "WHERE s.status IN ('active', 'suspended')", 1)
	}
	args := []any{}
	if customer != "" {
		query += fmt.Sprintf(" AND c.external_id = $%d", len(args)+1)
		args = append(args, customer)
	}
	if product != "" {
		query += fmt.Sprintf(" AND p.id = $%d", len(args)+1)
		args = append(args, product)
	}
	query += " ORDER BY c.display_name, p.id"
	rows, err := a.db.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]subscription, 0)
	for rows.Next() {
		var item subscription
		if err = rows.Scan(&item.ID, &item.CustomerID, &item.Customer, &item.Product, &item.Plan, &item.PlanName, &item.MonthlyCents, &item.Included, &item.MonthlyQuota, &item.OverageMicros, &item.RateLimit, &item.RateWindowSecs, &item.Version, &item.Status, &item.StartsAt, &item.EndsAt); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (a *app) loadSubscriptionsByIdentity(ctx context.Context, provider, subject, product string) ([]subscription, error) {
	return a.loadSubscriptionsByIdentityState(ctx, provider, subject, product, false)
}

func (a *app) loadManagedSubscriptionsByIdentity(ctx context.Context, provider, subject, product string) ([]subscription, error) {
	return a.loadSubscriptionsByIdentityState(ctx, provider, subject, product, true)
}

func (a *app) loadSubscriptionsByIdentityState(ctx context.Context, provider, subject, product string, includeSuspended bool) ([]subscription, error) {
	query := `
		SELECT s.id::text, c.external_id, c.display_name, p.id, s.plan_id,
		       pl.display_name, pl.monthly_price_cents, pl.included_requests,
		       pl.monthly_quota_requests, pl.overage_micros_per_request,
		       pl.rate_limit_requests,
		       pl.rate_limit_window_seconds, s.version,
		       s.status, s.starts_at, s.ends_at
		FROM monetization.subscription_identities i
		JOIN monetization.customers c ON c.id = i.customer_id
		JOIN monetization.subscriptions s ON s.customer_id = c.id
		JOIN monetization.api_products p ON p.id = s.api_product_id
		JOIN monetization.plans pl ON pl.id = s.plan_id
		WHERE i.provider = $1 AND i.subject = $2 AND i.status = 'active'
		  AND s.status = 'active'`
	if includeSuspended {
		query = strings.Replace(query, "AND s.status = 'active'", "AND s.status IN ('active', 'suspended')", 1)
	}
	args := []any{provider, subject}
	if product != "" {
		query += " AND s.api_product_id = $3"
		args = append(args, product)
	}
	query += " ORDER BY c.display_name, p.id"
	rows, err := a.db.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]subscription, 0)
	for rows.Next() {
		var item subscription
		if err = rows.Scan(&item.ID, &item.CustomerID, &item.Customer, &item.Product, &item.Plan, &item.PlanName, &item.MonthlyCents, &item.Included, &item.MonthlyQuota, &item.OverageMicros, &item.RateLimit, &item.RateWindowSecs, &item.Version, &item.Status, &item.StartsAt, &item.EndsAt); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (a *app) changePlan(w http.ResponseWriter, r *http.Request) {
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
	customer := r.PathValue("customer")
	current, err := a.loadSubscriptions(r.Context(), customer, "inventory")
	if err != nil || len(current) != 1 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "active customer subscription not found"})
		return
	}
	oldPlan := current[0].Plan
	apiKeyName := a.apiKeyName
	if customer != "demo-company" {
		apiKeyName, _ = selfServiceResourceNames(customer, "inventory")
	}
	if oldPlan == input.Plan {
		if err = a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, apiKeyName, input.Plan); err != nil {
			slog.Error("failed to reconcile RHCL API key plan", "error", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "RHCL API key plan update failed"})
			return
		}
		writeJSON(w, http.StatusOK, current[0])
		return
	}
	var exists bool
	if err = a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM monetization.plans WHERE id=$1 AND active)", input.Plan).Scan(&exists); err != nil || !exists {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown or inactive plan"})
		return
	}
	err = a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, apiKeyName, input.Plan)
	if err != nil {
		slog.Error("failed to update enforcement plan", "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "RHCL API key plan update failed"})
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err == nil {
		_, err = tx.Exec(r.Context(), `
			UPDATE monetization.subscriptions
			SET plan_id=$1, version=version+1, updated_at=now()
			WHERE id=$2::uuid`, input.Plan, current[0].ID)
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `
			INSERT INTO monetization.plan_changes
			(subscription_id, previous_plan_id, new_plan_id, changed_by, reason)
			VALUES ($1::uuid, $2, $3, 'monetization-control', 'live demo upgrade')`, current[0].ID, oldPlan, input.Plan)
	}
	if err == nil {
		err = tx.Commit(r.Context())
	} else if tx != nil {
		_ = tx.Rollback(r.Context())
	}
	if err != nil {
		rollbackErr := a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, apiKeyName, oldPlan)
		slog.Error("database update failed after enforcement update", "error", err, "enforcement_rollback_error", rollbackErr)
		serverError(w, err)
		return
	}
	a.upgradeCounter.Add(1)
	updated, err := a.loadSubscriptions(r.Context(), customer, "inventory")
	if err != nil {
		serverError(w, err)
		return
	}
	slog.Info("subscription plan changed", "customer", customer, "old_plan", oldPlan, "new_plan", input.Plan)
	writeJSON(w, http.StatusOK, updated[0])
}

func (a *app) changeSubscriptionStatus(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	var input struct {
		Status  string `json:"status"`
		Version int64  `json:"version"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must contain status and version"})
		return
	}
	input.Status = strings.ToLower(strings.TrimSpace(input.Status))
	if (input.Status != "active" && input.Status != "suspended") || input.Version < 1 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "status must be active or suspended with the current version"})
		return
	}
	customer := r.PathValue("customer")
	current, err := a.loadManagedSubscriptions(r.Context(), customer, "inventory")
	if err != nil || len(current) != 1 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "managed customer subscription not found"})
		return
	}
	if current[0].Status == input.Status {
		writeJSON(w, http.StatusOK, current[0])
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
		SET status=$1, version=version+1, updated_at=now()
		WHERE id=$2::uuid AND status=$3 AND version=$4`,
		input.Status, current[0].ID, current[0].Status, input.Version)
	if err != nil {
		serverError(w, err)
		return
	}
	if command.RowsAffected() != 1 {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "subscription changed; refresh before updating status"})
		return
	}
	actor := claims.PreferredUsername
	if actor == "" {
		actor = "monetization-admin"
	}
	_, err = tx.Exec(r.Context(), `
		INSERT INTO monetization.subscription_events
		(subscription_id, event_type, actor, details)
		VALUES ($1::uuid, $2, $3,
		        jsonb_build_object('previousStatus', $4::text, 'newStatus', $5::text))`,
		current[0].ID, "subscription-"+input.Status, actor,
		current[0].Status, input.Status)
	if err != nil {
		serverError(w, err)
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		serverError(w, err)
		return
	}
	updated, err := a.loadManagedSubscriptions(r.Context(), customer, "inventory")
	if err != nil || len(updated) != 1 {
		serverError(w, errors.New("updated subscription status was not found"))
		return
	}
	writeJSON(w, http.StatusOK, updated[0])
}

type kubeClient struct {
	baseURL string
	token   string
	client  *http.Client
}

func newKubeClient() (*kubeClient, error) {
	host := os.Getenv("KUBERNETES_SERVICE_HOST")
	port := env("KUBERNETES_SERVICE_PORT_HTTPS", "443")
	if host == "" {
		return nil, errors.New("KUBERNETES_SERVICE_HOST is empty")
	}
	token, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil {
		return nil, err
	}
	caPEM, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("failed to parse service account CA")
	}
	return &kubeClient{
		baseURL: "https://" + host + ":" + port,
		token:   strings.TrimSpace(string(token)),
		client:  &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool}}},
	}, nil
}

func (k *kubeClient) changeAPIKeyPlan(ctx context.Context, namespace, name, plan string) error {
	apiKeyPath := fmt.Sprintf("/apis/devportal.kuadrant.io/v1alpha1/namespaces/%s/apikeys/%s", namespace, name)
	return k.request(ctx, http.MethodPatch, apiKeyPath, map[string]any{"spec": map[string]string{"planTier": plan}}, nil)
}

func (k *kubeClient) routeHost(ctx context.Context, namespace, name string) (string, error) {
	var route struct {
		Status struct {
			Ingress []struct {
				Host       string `json:"host"`
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"ingress"`
		} `json:"status"`
	}
	path := fmt.Sprintf("/apis/route.openshift.io/v1/namespaces/%s/routes/%s", namespace, name)
	if err := k.request(ctx, http.MethodGet, path, nil, &route); err != nil {
		return "", err
	}
	for _, ingress := range route.Status.Ingress {
		for _, condition := range ingress.Conditions {
			if condition.Type == "Admitted" && condition.Status == "True" && ingress.Host != "" {
				return ingress.Host, nil
			}
		}
	}
	return "", errors.New("route is not admitted")
}

func (k *kubeClient) request(ctx context.Context, method, path string, body any, output any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, k.baseURL+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+k.token)
	req.Header.Set("Accept", "application/json")
	if method == http.MethodPatch {
		req.Header.Set("Content-Type", "application/merge-patch+json")
	} else if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return &kubeAPIError{StatusCode: resp.StatusCode, Method: method, Path: path, Message: strings.TrimSpace(string(message))}
	}
	if output != nil {
		return json.NewDecoder(resp.Body).Decode(output)
	}
	return nil
}

type kubeAPIError struct {
	StatusCode int
	Method     string
	Path       string
	Message    string
}

func (e *kubeAPIError) Error() string {
	return fmt.Sprintf("Kubernetes API %s %s returned HTTP %d: %s", e.Method, e.Path, e.StatusCode, e.Message)
}

func waitForDatabase(ctx context.Context, pool *pgxpool.Pool, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		attempt, cancel := context.WithTimeout(ctx, 3*time.Second)
		last = pool.Ping(attempt)
		cancel()
		if last == nil {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return last
}

func validIdentifier(value string) bool {
	if value == "" || len(value) > 63 || value[0] == '-' || value[len(value)-1] == '-' {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < '0' || char > '9') && char != '-' {
			return false
		}
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func serverError(w http.ResponseWriter, err error) {
	slog.Error("request failed", "error", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
}

func fatal(message string, err error) {
	slog.Error(message, "error", err)
	os.Exit(1)
}

func requiredEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		fatal("required environment variable is empty", fmt.Errorf("%s", name))
	}
	return value
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

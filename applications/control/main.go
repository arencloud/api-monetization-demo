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
	apiKeyName     string
	apiKeyNS       string
	upgradeCounter atomic.Uint64
}

type subscription struct {
	ID             string `json:"id"`
	CustomerID     string `json:"customerId"`
	Customer       string `json:"customer"`
	Product        string `json:"product"`
	Plan           string `json:"plan"`
	PlanName       string `json:"planName"`
	MonthlyCents   *int64 `json:"monthlyPriceCents"`
	Included       *int64 `json:"includedRequests"`
	RateLimit      *int32 `json:"rateLimitRequests"`
	RateWindowSecs *int32 `json:"rateLimitWindowSeconds"`
	Version        int64  `json:"version"`
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
	kube, err := newKubeClient()
	if err != nil {
		fatal("Kubernetes client configuration failed", err)
	}
	application := &app{
		db:         pool,
		kube:       kube,
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
	mux.HandleFunc("GET /api/plans", application.plans)
	mux.HandleFunc("GET /api/subscriptions", application.subscriptions)
	mux.HandleFunc("GET /internal/entitlements/{customer}/{product}", application.entitlement)
	mux.HandleFunc("GET /api/usage", application.usage)
	mux.HandleFunc("POST /api/subscriptions/{customer}/plan", application.changePlan)
	mux.HandleFunc("POST /internal/usage", application.recordUsage)
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
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	slog.Info("monetization control plane listening", "address", server.Addr)
	if err = server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fatal("server stopped", err)
	}
}

func (a *app) index(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	content, err := web.ReadFile("web/index.html")
	if err != nil {
		http.Error(w, "UI unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(content)
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
		       rate_limit_requests, rate_limit_window_seconds
		FROM monetization.plans WHERE active ORDER BY monthly_price_cents NULLS LAST`)
	if err != nil {
		serverError(w, err)
		return
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	for rows.Next() {
		var id, name string
		var monthly, included *int64
		var limit, window *int32
		if err = rows.Scan(&id, &name, &monthly, &included, &limit, &window); err != nil {
			serverError(w, err)
			return
		}
		result = append(result, map[string]any{"id": id, "displayName": name, "monthlyPriceCents": monthly, "includedRequests": included, "rateLimitRequests": limit, "rateLimitWindowSeconds": window})
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) subscriptions(w http.ResponseWriter, r *http.Request) {
	result, err := a.loadSubscriptions(r.Context(), "", "")
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
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "active subscription not found"})
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
	rows, err := a.db.Query(ctx, `
		SELECT c.external_id, s.api_product_id, s.plan_id, count(u.id),
		       p.included_requests,
		       GREATEST(count(u.id) - COALESCE(p.included_requests, count(u.id)), 0),
		       ((COALESCE(p.monthly_price_cents, 0)::numeric / 100)
		       + (GREATEST(count(u.id) - COALESCE(p.included_requests, count(u.id)), 0)
		          * p.overage_micros_per_request::numeric / 1000000))::double precision
		FROM monetization.subscriptions s
		JOIN monetization.customers c ON c.id=s.customer_id
		JOIN monetization.plans p ON p.id=s.plan_id
		LEFT JOIN monetization.usage_events u ON u.subscription_id=s.id
		WHERE s.status='active'
		GROUP BY c.external_id, s.api_product_id, s.plan_id, p.included_requests,
		         p.monthly_price_cents, p.overage_micros_per_request
		ORDER BY c.external_id, s.api_product_id`)
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
	query := `
		SELECT s.id::text, c.external_id, c.display_name, p.id, s.plan_id,
		       pl.display_name, pl.monthly_price_cents, pl.included_requests,
		       pl.rate_limit_requests, pl.rate_limit_window_seconds, s.version
		FROM monetization.subscriptions s
		JOIN monetization.customers c ON c.id = s.customer_id
		JOIN monetization.api_products p ON p.id = s.api_product_id
		JOIN monetization.plans pl ON pl.id = s.plan_id
		WHERE s.status = 'active'`
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
		if err = rows.Scan(&item.ID, &item.CustomerID, &item.Customer, &item.Product, &item.Plan, &item.PlanName, &item.MonthlyCents, &item.Included, &item.RateLimit, &item.RateWindowSecs, &item.Version); err != nil {
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
	if oldPlan == input.Plan {
		if err = a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, a.apiKeyName, input.Plan); err != nil {
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
	err = a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, a.apiKeyName, input.Plan)
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
		rollbackErr := a.kube.changeAPIKeyPlan(r.Context(), a.apiKeyNS, a.apiKeyName, oldPlan)
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
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("Kubernetes API %s %s returned %s: %s", method, path, resp.Status, strings.TrimSpace(string(message)))
	}
	if output != nil {
		return json.NewDecoder(resp.Body).Decode(output)
	}
	return nil
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
	if value == "" || len(value) > 32 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && char != '-' {
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

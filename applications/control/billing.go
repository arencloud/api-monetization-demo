package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

type invoiceItem struct {
	SubscriptionID string `json:"subscriptionId"`
	Product        string `json:"product"`
	UnitName       string `json:"unitName"`
	Plan           string `json:"plan"`
	PlanName       string `json:"planName"`
	Description    string `json:"description"`
	BillableUnits  int64  `json:"billableUnits"`
	IncludedUnits  *int64 `json:"includedUnits"`
	OverageUnits   int64  `json:"overageUnits"`
	BaseCents      int64  `json:"baseCents"`
	OverageCents   int64  `json:"overageCents"`
	TotalCents     int64  `json:"totalCents"`
}

type invoice struct {
	ID            string        `json:"id,omitempty"`
	CustomerID    string        `json:"customerId"`
	Customer      string        `json:"customer"`
	PeriodStart   string        `json:"periodStart"`
	PeriodEnd     string        `json:"periodEnd"`
	Currency      string        `json:"currency"`
	SubtotalCents int64         `json:"subtotalCents"`
	OverageCents  int64         `json:"overageCents"`
	TotalCents    int64         `json:"totalCents"`
	Status        string        `json:"status"`
	CreatedAt     *time.Time    `json:"createdAt,omitempty"`
	UpdatedAt     *time.Time    `json:"updatedAt,omitempty"`
	Items         []invoiceItem `json:"items"`
}

type lifecycleEvent struct {
	Type        string    `json:"type"`
	Description string    `json:"description"`
	OccurredAt  time.Time `json:"occurredAt"`
}

func currentBillingPeriod(now time.Time) (time.Time, time.Time) {
	utc := now.UTC()
	start := time.Date(utc.Year(), utc.Month(), 1, 0, 0, 0, 0, time.UTC)
	return start, start.AddDate(0, 1, 0)
}

func roundMicrosToCents(micros int64) int64 {
	if micros <= 0 {
		return 0
	}
	return (micros + 5000) / 10000
}

func (a *app) calculateInvoice(ctx context.Context, customerID string, start, end time.Time) (invoice, error) {
	result := invoice{
		CustomerID:  customerID,
		PeriodStart: start.Format(time.DateOnly),
		PeriodEnd:   end.Format(time.DateOnly),
		Currency:    "EUR",
		Status:      "preview",
		Items:       make([]invoiceItem, 0),
	}
	rows, err := a.db.Query(ctx, `
		SELECT s.id::text, c.display_name, s.api_product_id, ap.unit_name, s.plan_id,
		       p.display_name, COALESCE(pp.monthly_price_cents, p.monthly_price_cents, 0),
		       COALESCE(pp.included_units, p.included_requests),
		       COALESCE(pp.overage_micros_per_unit, p.overage_micros_per_request),
		       COALESCE(SUM(u.billable_units), 0)::bigint
		FROM monetization.subscriptions s
		JOIN monetization.customers c ON c.id=s.customer_id
		JOIN monetization.api_products ap ON ap.id=s.api_product_id
		JOIN monetization.plans p ON p.id=s.plan_id
		JOIN monetization.api_product_plans pp
		  ON pp.api_product_id=s.api_product_id AND pp.plan_id=s.plan_id
		LEFT JOIN monetization.usage_events u ON u.subscription_id=s.id
		  AND u.occurred_at >= $2 AND u.occurred_at < $3
		WHERE c.external_id=$1
		  AND s.starts_at < $3
		  AND (s.ends_at IS NULL OR s.ends_at >= $2)
		  AND s.status IN ('active', 'suspended', 'cancelled')
		GROUP BY s.id, c.display_name, s.api_product_id, ap.unit_name, s.plan_id,
		         p.display_name, p.monthly_price_cents,
		         p.included_requests, p.overage_micros_per_request,
		         pp.monthly_price_cents, pp.included_units, pp.overage_micros_per_unit
		ORDER BY s.created_at, s.api_product_id`, customerID, start, end)
	if err != nil {
		return invoice{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var item invoiceItem
		var customerName string
		var overageMicros int64
		if err = rows.Scan(&item.SubscriptionID, &customerName, &item.Product, &item.UnitName, &item.Plan,
			&item.PlanName, &item.BaseCents, &item.IncludedUnits, &overageMicros,
			&item.BillableUnits); err != nil {
			return invoice{}, err
		}
		result.Customer = customerName
		if item.IncludedUnits != nil && item.BillableUnits > *item.IncludedUnits {
			item.OverageUnits = item.BillableUnits - *item.IncludedUnits
		}
		item.OverageCents = roundMicrosToCents(item.OverageUnits * overageMicros)
		item.TotalCents = item.BaseCents + item.OverageCents
		item.Description = fmt.Sprintf("%s · %s plan", item.Product, item.PlanName)
		result.SubtotalCents += item.BaseCents
		result.OverageCents += item.OverageCents
		result.TotalCents += item.TotalCents
		result.Items = append(result.Items, item)
	}
	return result, rows.Err()
}

func (a *app) createDraftInvoice(ctx context.Context, customerID string) (invoice, error) {
	start, end := currentBillingPeriod(time.Now())
	result, err := a.calculateInvoice(ctx, customerID, start, end)
	if err != nil {
		return invoice{}, err
	}
	if result.Customer == "" || len(result.Items) == 0 {
		return invoice{}, pgx.ErrNoRows
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return invoice{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var invoiceID string
	var createdAt, updatedAt time.Time
	err = tx.QueryRow(ctx, `
		INSERT INTO monetization.invoices
		(customer_id, period_start, period_end, currency, subtotal_cents,
		 overage_cents, total_cents, status)
		SELECT id, $2, $3, $4, $5, $6, $7, 'draft'
		FROM monetization.customers WHERE external_id=$1
		ON CONFLICT (customer_id, period_start, period_end) DO UPDATE SET
		  subtotal_cents=EXCLUDED.subtotal_cents,
		  overage_cents=EXCLUDED.overage_cents,
		  total_cents=EXCLUDED.total_cents,
		  updated_at=now()
		WHERE monetization.invoices.status='draft'
		RETURNING id::text, created_at, updated_at`, customerID, start, end,
		result.Currency, result.SubtotalCents, result.OverageCents, result.TotalCents).
		Scan(&invoiceID, &createdAt, &updatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return invoice{}, errors.New("the current invoice is no longer a draft")
		}
		return invoice{}, err
	}
	if _, err = tx.Exec(ctx, `DELETE FROM monetization.invoice_items WHERE invoice_id=$1::uuid`, invoiceID); err != nil {
		return invoice{}, err
	}
	for _, item := range result.Items {
		_, err = tx.Exec(ctx, `
			INSERT INTO monetization.invoice_items
			(invoice_id, subscription_id, api_product_id, plan_id, description,
			 billable_units, included_units, overage_units, base_cents,
			 overage_cents, total_cents)
			VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
			invoiceID, item.SubscriptionID, item.Product, item.Plan, item.Description,
			item.BillableUnits, item.IncludedUnits, item.OverageUnits, item.BaseCents,
			item.OverageCents, item.TotalCents)
		if err != nil {
			return invoice{}, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return invoice{}, err
	}
	result.ID = invoiceID
	result.Status = "draft"
	result.CreatedAt = &createdAt
	result.UpdatedAt = &updatedAt
	return result, nil
}

func (a *app) loadInvoices(ctx context.Context, customerID string) ([]invoice, error) {
	query := `
		SELECT i.id::text, c.external_id, c.display_name, i.period_start,
		       i.period_end, i.currency, i.subtotal_cents, i.overage_cents,
		       i.total_cents, i.status, i.created_at, i.updated_at
		FROM monetization.invoices i
		JOIN monetization.customers c ON c.id=i.customer_id`
	args := []any{}
	if customerID != "" {
		query += " WHERE c.external_id=$1"
		args = append(args, customerID)
	}
	query += " ORDER BY i.period_start DESC, c.display_name"
	rows, err := a.db.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	result := make([]invoice, 0)
	for rows.Next() {
		var item invoice
		var start, end time.Time
		var created, updated time.Time
		if err = rows.Scan(&item.ID, &item.CustomerID, &item.Customer, &start,
			&end, &item.Currency, &item.SubtotalCents, &item.OverageCents,
			&item.TotalCents, &item.Status, &created, &updated); err != nil {
			return nil, err
		}
		item.PeriodStart = start.Format(time.DateOnly)
		item.PeriodEnd = end.Format(time.DateOnly)
		item.CreatedAt = &created
		item.UpdatedAt = &updated
		result = append(result, item)
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	for index := range result {
		result[index].Items, err = a.loadInvoiceItems(ctx, result[index].ID)
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}

func (a *app) loadInvoiceItems(ctx context.Context, invoiceID string) ([]invoiceItem, error) {
	rows, err := a.db.Query(ctx, `
		SELECT ii.subscription_id::text, ii.api_product_id, ap.unit_name, ii.plan_id,
		       p.display_name, ii.description, ii.billable_units,
		       ii.included_units, ii.overage_units, ii.base_cents,
		       ii.overage_cents, ii.total_cents
		FROM monetization.invoice_items ii
		JOIN monetization.plans p ON p.id=ii.plan_id
		JOIN monetization.api_products ap ON ap.id=ii.api_product_id
		WHERE ii.invoice_id=$1::uuid ORDER BY ii.api_product_id`, invoiceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]invoiceItem, 0)
	for rows.Next() {
		var item invoiceItem
		if err = rows.Scan(&item.SubscriptionID, &item.Product, &item.UnitName, &item.Plan,
			&item.PlanName, &item.Description, &item.BillableUnits,
			&item.IncludedUnits, &item.OverageUnits, &item.BaseCents,
			&item.OverageCents, &item.TotalCents); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (a *app) loadLifecycleEvents(ctx context.Context, customerID string) ([]lifecycleEvent, error) {
	rows, err := a.db.Query(ctx, `
		SELECT event_type, description, occurred_at FROM (
		  SELECT 'subscription-created' AS event_type,
		         'Subscription created for ' || s.api_product_id AS description,
		         s.created_at AS occurred_at
		  FROM monetization.subscriptions s
		  JOIN monetization.customers c ON c.id=s.customer_id
		  WHERE c.external_id=$1
		  UNION ALL
		  SELECT 'plan-changed',
		         'Plan changed from ' || COALESCE(pc.previous_plan_id, 'none') || ' to ' || pc.new_plan_id || ' by ' || pc.changed_by,
		         pc.changed_at
		  FROM monetization.plan_changes pc
		  JOIN monetization.subscriptions s ON s.id=pc.subscription_id
		  JOIN monetization.customers c ON c.id=s.customer_id
		  WHERE c.external_id=$1
		  UNION ALL
		  SELECT 'credential-created', 'API key generated with prefix ' || ac.key_prefix, ac.created_at
		  FROM monetization.api_credentials ac
		  JOIN monetization.subscriptions s ON s.id=ac.subscription_id
		  JOIN monetization.customers c ON c.id=s.customer_id
		  WHERE c.external_id=$1
		  UNION ALL
		  SELECT 'credential-revoked', 'API key revoked with prefix ' || ac.key_prefix, ac.revoked_at
		  FROM monetization.api_credentials ac
		  JOIN monetization.subscriptions s ON s.id=ac.subscription_id
		  JOIN monetization.customers c ON c.id=s.customer_id
		  WHERE c.external_id=$1 AND ac.revoked_at IS NOT NULL
		  UNION ALL
		  SELECT se.event_type,
		         CASE se.event_type
		           WHEN 'subscription-suspended' THEN 'Subscription suspended by ' || se.actor
		           WHEN 'subscription-active' THEN 'Subscription resumed by ' || se.actor
		           WHEN 'subscription-cancelled' THEN 'Subscription cancelled by ' || se.actor
		           ELSE se.event_type || ' by ' || se.actor
		         END,
		         se.occurred_at
		  FROM monetization.subscription_events se
		  JOIN monetization.subscriptions s ON s.id=se.subscription_id
		  JOIN monetization.customers c ON c.id=s.customer_id
		  WHERE c.external_id=$1
		) events ORDER BY occurred_at DESC LIMIT 100`, customerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]lifecycleEvent, 0)
	for rows.Next() {
		var item lifecycleEvent
		if err = rows.Scan(&item.Type, &item.Description, &item.OccurredAt); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (a *app) myBilling(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer billing account not found"})
		return
	}
	start, end := currentBillingPeriod(time.Now())
	preview, err := a.calculateInvoice(r.Context(), customer.ExternalID, start, end)
	if err != nil {
		serverError(w, err)
		return
	}
	invoices, err := a.loadInvoices(r.Context(), customer.ExternalID)
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"preview": preview, "invoices": invoices})
}

func (a *app) createMyDraftInvoice(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer billing account not found"})
		return
	}
	result, err := a.createDraftInvoice(r.Context(), customer.ExternalID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "there is no subscription activity to invoice"})
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

func (a *app) myAudit(w http.ResponseWriter, r *http.Request) {
	claims, _ := authenticatedClaims(r.Context())
	customer, err := a.developerCustomer(r.Context(), claims.Subject)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "developer account not found"})
		return
	}
	result, err := a.loadLifecycleEvents(r.Context(), customer.ExternalID)
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) invoices(w http.ResponseWriter, r *http.Request) {
	result, err := a.loadInvoices(r.Context(), "")
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) createCustomerDraftInvoice(w http.ResponseWriter, r *http.Request) {
	customerID := r.PathValue("customer")
	if !validIdentifier(customerID) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid customer"})
		return
	}
	result, err := a.createDraftInvoice(r.Context(), customerID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "there is no subscription activity to invoice"})
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

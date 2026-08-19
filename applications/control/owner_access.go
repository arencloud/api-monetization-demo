package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type ownerAccessRequest struct {
	ID             string     `json:"id"`
	Subject        string     `json:"subject"`
	Username       string     `json:"username"`
	Email          string     `json:"email"`
	Justification  string     `json:"justification"`
	Status         string     `json:"status"`
	ReviewedBy     *string    `json:"reviewedBy,omitempty"`
	DecisionReason *string    `json:"decisionReason,omitempty"`
	CreatedAt      time.Time  `json:"createdAt"`
	UpdatedAt      time.Time  `json:"updatedAt"`
	ReviewedAt     *time.Time `json:"reviewedAt,omitempty"`
}

func scanOwnerAccessRequest(row pgx.Row) (ownerAccessRequest, error) {
	var result ownerAccessRequest
	err := row.Scan(&result.ID, &result.Subject, &result.Username, &result.Email,
		&result.Justification, &result.Status, &result.ReviewedBy,
		&result.DecisionReason, &result.CreatedAt, &result.UpdatedAt, &result.ReviewedAt)
	return result, err
}

const ownerAccessColumns = `id::text, subject, username, email, justification,
  status, reviewed_by, decision_reason, created_at, updated_at, reviewed_at`

func (a *app) myOwnerAccess(w http.ResponseWriter, r *http.Request) {
	claims, ok := authenticatedClaims(r.Context())
	if !ok {
		authError(w, http.StatusUnauthorized, "authenticated identity required")
		return
	}
	request, err := scanOwnerAccessRequest(a.db.QueryRow(r.Context(), `
		SELECT `+ownerAccessColumns+` FROM monetization.owner_access_requests
		WHERE subject=$1 ORDER BY created_at DESC LIMIT 1`, claims.Subject))
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		serverError(w, err)
		return
	}
	response := map[string]any{
		"owner": contains(claims.RealmAccess.Roles, portalOwnerRole),
	}
	if err == nil {
		response["request"] = request
	} else {
		response["request"] = nil
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *app) requestOwnerAccess(w http.ResponseWriter, r *http.Request) {
	claims, ok := authenticatedClaims(r.Context())
	if !ok {
		authError(w, http.StatusUnauthorized, "authenticated identity required")
		return
	}
	if contains(claims.RealmAccess.Roles, portalOwnerRole) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "identity is already an API owner"})
		return
	}
	var input struct {
		Justification string `json:"justification"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "valid justification is required"})
		return
	}
	input.Justification = strings.TrimSpace(input.Justification)
	if len(input.Justification) < 10 || len(input.Justification) > 1000 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "justification must contain 10 to 1000 characters"})
		return
	}
	username := strings.TrimSpace(claims.PreferredUsername)
	if username == "" {
		username = claims.Subject
	}
	request, err := scanOwnerAccessRequest(a.db.QueryRow(r.Context(), `
		INSERT INTO monetization.owner_access_requests
		(subject, username, email, justification)
		VALUES ($1, $2, $3, $4)
		RETURNING `+ownerAccessColumns,
		claims.Subject, username, claims.Email, input.Justification))
	if err != nil {
		var databaseError *pgconn.PgError
		if errors.As(err, &databaseError) && databaseError.Code == "23505" {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "an owner access request is already pending"})
			return
		}
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, request)
}

func (a *app) ownerAccessRequests(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT `+ownerAccessColumns+`
		FROM monetization.owner_access_requests
		ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END, created_at DESC
		LIMIT 200`)
	if err != nil {
		serverError(w, err)
		return
	}
	defer rows.Close()
	result := make([]ownerAccessRequest, 0)
	for rows.Next() {
		item, scanErr := scanOwnerAccessRequest(rows)
		if scanErr != nil {
			serverError(w, scanErr)
			return
		}
		result = append(result, item)
	}
	if err = rows.Err(); err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *app) decideOwnerAccess(w http.ResponseWriter, r *http.Request) {
	requestID := strings.ToLower(r.PathValue("id"))
	if !uuidPattern.MatchString(requestID) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "valid owner request ID required"})
		return
	}
	var input struct {
		Decision string `json:"decision"`
		Reason   string `json:"reason"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "valid decision is required"})
		return
	}
	input.Decision = strings.ToLower(strings.TrimSpace(input.Decision))
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Decision != "approved" && input.Decision != "rejected" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "decision must be approved or rejected"})
		return
	}
	if len(input.Reason) > 1000 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "decision reason is too long"})
		return
	}
	claims, _ := authenticatedClaims(r.Context())
	reviewer := claims.PreferredUsername
	if reviewer == "" {
		reviewer = claims.Subject
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		serverError(w, err)
		return
	}
	defer func() { _ = tx.Rollback(r.Context()) }()
	request, err := scanOwnerAccessRequest(tx.QueryRow(r.Context(), `
		SELECT `+ownerAccessColumns+` FROM monetization.owner_access_requests
		WHERE id=$1::uuid FOR UPDATE`, requestID))
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "owner access request not found"})
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	if request.Status != "pending" {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "owner access request was already decided"})
		return
	}
	if input.Decision == "approved" {
		if err = a.ownerApproval.setOwner(r.Context(), request.Subject); err != nil {
			serverError(w, err)
			return
		}
	}
	request, err = scanOwnerAccessRequest(tx.QueryRow(r.Context(), `
		UPDATE monetization.owner_access_requests SET status=$2, reviewed_by=$3,
		  decision_reason=NULLIF($4, ''), reviewed_at=now(), updated_at=now()
		WHERE id=$1::uuid RETURNING `+ownerAccessColumns,
		requestID, input.Decision, reviewer, input.Reason))
	if err != nil {
		serverError(w, err)
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, request)
}

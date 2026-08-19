package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type keycloakAdminClient struct {
	baseURL      string
	realm        string
	clientID     string
	clientSecret string
	http         *http.Client
	mu           sync.Mutex
	token        string
	tokenExpiry  time.Time
}

type keycloakTokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int64  `json:"expires_in"`
}

type keycloakGroup struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func newKeycloakAdminClient(clientSecret string) (*keycloakAdminClient, error) {
	if strings.TrimSpace(clientSecret) == "" {
		return nil, errors.New("owner approval Keycloak client secret is required")
	}
	return &keycloakAdminClient{
		baseURL:      keycloakInternalURL,
		realm:        keycloakRealm,
		clientID:     "monetization-owner-approvals",
		clientSecret: clientSecret,
		http:         &http.Client{Timeout: 15 * time.Second},
	}, nil
}

func (c *keycloakAdminClient) accessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Add(15*time.Second).Before(c.tokenExpiry) {
		return c.token, nil
	}
	form := url.Values{
		"grant_type":    {"client_credentials"},
		"client_id":     {c.clientID},
		"client_secret": {c.clientSecret},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token", c.baseURL, c.realm),
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("Keycloak service token returned HTTP %d", response.StatusCode)
	}
	var token keycloakTokenResponse
	if err = json.NewDecoder(response.Body).Decode(&token); err != nil {
		return "", err
	}
	if token.AccessToken == "" {
		return "", errors.New("Keycloak service token was empty")
	}
	c.token = token.AccessToken
	c.tokenExpiry = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second)
	return c.token, nil
}

func (c *keycloakAdminClient) request(ctx context.Context, method, path string) (*http.Response, error) {
	token, err := c.accessToken(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, method,
		fmt.Sprintf("%s/admin/realms/%s/%s", c.baseURL, c.realm, strings.TrimLeft(path, "/")), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	return c.http.Do(req)
}

func (c *keycloakAdminClient) groupID(ctx context.Context, name string) (string, error) {
	response, err := c.request(ctx, http.MethodGet, "groups?search="+url.QueryEscape(name)+"&exact=true")
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("query Keycloak group %s returned HTTP %d", name, response.StatusCode)
	}
	var groups []keycloakGroup
	if err = json.NewDecoder(response.Body).Decode(&groups); err != nil {
		return "", err
	}
	for _, group := range groups {
		if group.Name == name && group.ID != "" {
			return group.ID, nil
		}
	}
	return "", fmt.Errorf("Keycloak group %s was not found", name)
}

func (c *keycloakAdminClient) setOwner(ctx context.Context, subject string) error {
	ownerID, err := c.groupID(ctx, "api-owners")
	if err != nil {
		return err
	}
	consumerID, err := c.groupID(ctx, "api-consumers")
	if err != nil {
		return err
	}
	response, err := c.request(ctx, http.MethodPut,
		fmt.Sprintf("users/%s/groups/%s", url.PathEscape(subject), url.PathEscape(ownerID)))
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return fmt.Errorf("add API owner membership returned HTTP %d", response.StatusCode)
	}
	response, err = c.request(ctx, http.MethodDelete,
		fmt.Sprintf("users/%s/groups/%s", url.PathEscape(subject), url.PathEscape(consumerID)))
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return fmt.Errorf("remove API consumer membership returned HTTP %d", response.StatusCode)
	}
	return nil
}

package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMockModeFromEnv(t *testing.T) {
	t.Setenv("MOCK_MODE", "fixed")
	got := loadConfigFromEnv()
	if !got.mockFixedResponse {
		t.Fatalf("expected mockFixedResponse=true")
	}
}

func TestFraudScoreMockFixedResponse(t *testing.T) {
	a := &app{instanceID: "1", ready: true, mockFixed: true, metrics: &metrics{}}
	req := httptest.NewRequest(http.MethodPost, "/fraud-score", bytes.NewBufferString(`{"transaction":{"amount":10,"installments":1}}`))
	rr := httptest.NewRecorder()

	a.handleFraudScore(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, `"approved":true`) {
		t.Fatalf("unexpected body: %s", body)
	}
	if !strings.Contains(body, `"fraud_score":0.01`) {
		t.Fatalf("unexpected body: %s", body)
	}
}

package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPortFromPath(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"/":             "",
		"/8080":         "8080",
		"/8080/":        "8080",
		"/8080/details": "8080",
		"8443":          "8443",
	}

	for input, want := range tests {
		input := input
		want := want

		t.Run(input, func(t *testing.T) {
			t.Parallel()

			if got := portFromPath(input); got != want {
				t.Fatalf("portFromPath(%q) = %q, want %q", input, got, want)
			}
		})
	}
}

func TestHealthzHandler(t *testing.T) {
	t.Parallel()

	handler := newHandler(slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}

	if body := response.Body.String(); body != "ok" {
		t.Fatalf("body = %q, want %q", body, "ok")
	}
}

func TestPortEchoHandler(t *testing.T) {
	t.Parallel()

	handler := newHandler(slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/2053/probe", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}

	if body := response.Body.String(); body != "2053" {
		t.Fatalf("body = %q, want %q", body, "2053")
	}
}

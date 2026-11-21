package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestReadyWithoutDatabase(t *testing.T) {
	t.Setenv("DB_HOST", "")
	rr := httptest.NewRecorder()
	ready(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("readyz without a database: got %d, want 200", rr.Code)
	}
}

func TestReadyWithUnreachableDatabase(t *testing.T) {
	t.Setenv("DB_HOST", "127.0.0.1")
	t.Setenv("DB_PORT", "1")
	rr := httptest.NewRecorder()
	ready(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz with an unreachable database: got %d, want 503", rr.Code)
	}
}

func TestProbeIsOffByDefault(t *testing.T) {
	mux := http.NewServeMux()
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/probe/dns?host=localhost", nil))
	if rr.Code != http.StatusNotFound {
		t.Fatalf("probe without PROBE=1: got %d, want 404", rr.Code)
	}
}

func TestProbeDNS(t *testing.T) {
	mux := http.NewServeMux()
	probe(mux)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/probe/dns?host=localhost", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("probe dns localhost: got %d, want 200 (%s)", rr.Code, rr.Body.String())
	}
}

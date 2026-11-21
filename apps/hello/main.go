// hello is the platform's sample app (contract P1–P4 journeys). It serves HTTP on $PORT (default 8080) and, when a
// database is declared, its readiness probe runs a real query through the brokered credential (ADR-0002 step 3).
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

var version = "dev" // set at build time: -ldflags "-X main.version=<git sha>"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// dbConnString builds a libpq connection string from the brokered Secret's keys (host, port, username, password,
// dbname), mounted as environment variables by the golden-service chart. Empty when no database is declared.
func dbConnString() string {
	host := os.Getenv("DB_HOST")
	if host == "" {
		return ""
	}
	return fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=%s connect_timeout=3",
		host, env("DB_PORT", "5432"), os.Getenv("DB_USERNAME"), os.Getenv("DB_PASSWORD"), env("DB_NAME", "app"),
		env("DB_SSLMODE", "require"))
}

func ready(w http.ResponseWriter, r *http.Request) {
	cs := dbConnString()
	if cs == "" {
		fmt.Fprintln(w, "ready (no database declared)")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, cs)
	if err != nil {
		log.Printf("readiness: connect: %v", err)
		http.Error(w, "database: connect failed", http.StatusServiceUnavailable)
		return
	}
	defer conn.Close(ctx)
	var one int
	if err := conn.QueryRow(ctx, "select 1").Scan(&one); err != nil || one != 1 {
		log.Printf("readiness: query: %v", err)
		http.Error(w, "database: query failed", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "ready (database query ok)")
}

// probe serves the network-contract suite (tests/e2e/network-contract) only; it is off unless PROBE=1.
// /probe/dns?host=  resolves a name (DNS egress); /probe/http?url=  makes one GET with a 3 s timeout (L3/L4 egress).
func probe(mux *http.ServeMux) {
	client := &http.Client{Timeout: 3 * time.Second}
	mux.HandleFunc("/probe/dns", func(w http.ResponseWriter, r *http.Request) {
		addrs, err := net.DefaultResolver.LookupHost(r.Context(), r.URL.Query().Get("host"))
		if err != nil {
			http.Error(w, "dns: "+err.Error(), http.StatusBadGateway)
			return
		}
		fmt.Fprintf(w, "dns ok %v\n", addrs)
	})
	mux.HandleFunc("/probe/http", func(w http.ResponseWriter, r *http.Request) {
		resp, err := client.Get(r.URL.Query().Get("url"))
		if err != nil {
			http.Error(w, "http: "+err.Error(), http.StatusBadGateway)
			return
		}
		resp.Body.Close()
		fmt.Fprintf(w, "http ok %d\n", resp.StatusCode)
	})
}

func main() {
	app, appEnv, track := env("APP_NAME", "hello"), env("APP_ENV", "dev"), env("TRACK", "stable")
	mux := http.NewServeMux()
	if os.Getenv("PROBE") == "1" {
		probe(mux)
	}
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })
	mux.HandleFunc("/readyz", ready)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-App-Version", version)
		w.Header().Set("X-App-Track", track)
		// Echo the gateway's request-header modifier back, so the network contract can observe it (route feature 5).
		if v := r.Header.Get("X-Request-Tag"); v != "" {
			w.Header().Set("X-Echo-Request-Tag", v)
		}
		fmt.Fprintf(w, "hello from %s (%s), track %s, version %s, path %s\n", app, appEnv, track, version, r.URL.Path)
	})
	addr := ":" + env("PORT", "8080")
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("%s %s listening on %s", app, version, addr)
	log.Fatal(srv.ListenAndServe())
}

package main

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ─────────────────────────────────────────────────────────────────────────────
// TLS — server + client configs
// ─────────────────────────────────────────────────────────────────────────────

// loadServerTLS builds a *tls.Config for serving (inbound connections).
// When TLS_CA is set, mutual TLS is enforced: the peer must present a cert.
// Returns nil if TLS_CERT / TLS_KEY are not set.
func loadServerTLS() *tls.Config {
	certFile := getenv("TLS_CERT", "")
	keyFile := getenv("TLS_KEY", "")
	caFile := getenv("TLS_CA", "")
	if certFile == "" || keyFile == "" {
		return nil
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("TLS: failed to load cert/key: %v", err)
	}
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	if caFile != "" {
		pool := mustLoadCertPool(caFile)
		cfg.ClientCAs = pool
		cfg.ClientAuth = tls.RequireAndVerifyClientCert
	}
	return cfg
}

// buildClientTLS builds a *tls.Config for outbound connections.
// Returns nil if the env vars are not set.
func buildClientTLS() *tls.Config {
	certFile := getenv("TLS_CERT", "")
	keyFile := getenv("TLS_KEY", "")
	caFile := getenv("TLS_CA", "")
	if certFile == "" || keyFile == "" || caFile == "" {
		return nil
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("TLS client: failed to load cert/key: %v", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      mustLoadCertPool(caFile),
		MinVersion:   tls.VersionTLS12,
	}
}

func mustLoadCertPool(caFile string) *x509.CertPool {
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		log.Fatalf("TLS: failed to read CA %s: %v", caFile, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		log.Fatalf("TLS: failed to parse CA %s", caFile)
	}
	return pool
}

// listenAndServe binds to LISTEN_ADDR (default 127.0.0.1).
// Pod-a and pod-b apps keep the default: all inbound traffic arrives through
// the Envoy sidecar so the app is never reachable directly from the network.
// Mock targets set LISTEN_ADDR=0.0.0.0 because they have no sidecar — Envoy
// from other pods connects to them directly, as does the kubelet health check.
func listenAndServe(port string, handler http.Handler, tlsCfg *tls.Config) error {
	addr := getenv("LISTEN_ADDR", "127.0.0.1") + ":" + port
	if tlsCfg != nil {
		ln, err := tls.Listen("tcp", addr, tlsCfg)
		if err != nil {
			return err
		}
		log.Printf("listening on %s (HTTPS/mTLS)", addr)
		return http.Serve(ln, handler)
	}
	log.Printf("listening on %s (HTTP)", addr)
	return http.ListenAndServe(addr, handler)
}

// ─────────────────────────────────────────────────────────────────────────────
// JWT validation (RS256, stdlib only — no external dependencies)
// ─────────────────────────────────────────────────────────────────────────────

type jwtClaims struct {
	Iss string `json:"iss"`
	Aud string `json:"aud"`
	Exp int64  `json:"exp"`
	Iat int64  `json:"iat"`
}

// loadRSAPublicKey reads an RSA public key from a PEM file.
func loadRSAPublicKey(path string) *rsa.PublicKey {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		log.Fatalf("JWT: cannot read public key %s: %v", path, err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		log.Fatalf("JWT: failed to decode PEM from %s", path)
	}
	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		log.Fatalf("JWT: cannot parse public key %s: %v", path, err)
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		log.Fatalf("JWT: key in %s is not RSA", path)
	}
	log.Printf("JWT: loaded public key from %s", path)
	return rsaPub
}

// validateRS256JWT verifies the signature, expiry, and issuer of a JWT.
func validateRS256JWT(tokenStr string, pub *rsa.PublicKey) error {
	parts := strings.SplitN(tokenStr, ".", 3)
	if len(parts) != 3 {
		return fmt.Errorf("malformed token (expected 3 parts, got %d)", len(parts))
	}

	// Verify RS256 signature over header.payload
	message := parts[0] + "." + parts[1]
	h := sha256.Sum256([]byte(message))
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return fmt.Errorf("bad signature encoding: %w", err)
	}
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, h[:], sig); err != nil {
		return fmt.Errorf("signature invalid: %w", err)
	}

	// Decode and validate claims
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return fmt.Errorf("bad payload encoding: %w", err)
	}
	var claims jwtClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return fmt.Errorf("bad payload JSON: %w", err)
	}
	if claims.Iss != "envoy-sidecar" {
		return fmt.Errorf("unexpected issuer %q", claims.Iss)
	}
	if time.Now().Unix() > claims.Exp {
		return fmt.Errorf("token expired at %d (now %d)", claims.Exp, time.Now().Unix())
	}
	return nil
}

// jwtMiddleware validates the X-Envoy-Internal-JWT header on every request.
// The /health path is exempt so readiness probes work without a token.
func jwtMiddleware(pub *rsa.PublicKey, headerName string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}
		raw := r.Header.Get(headerName)
		if raw == "" {
			log.Printf("JWT: missing header %q on %s %s from %s", headerName, r.Method, r.URL.Path, r.RemoteAddr)
			http.Error(w, "missing internal auth header", http.StatusUnauthorized)
			return
		}
		token := strings.TrimPrefix(raw, "Bearer ")
		if err := validateRS256JWT(token, pub); err != nil {
			log.Printf("JWT: invalid token on %s %s: %v", r.Method, r.URL.Path, err)
			http.Error(w, "invalid internal auth", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ─────────────────────────────────────────────────────────────────────────────
// Outbound helpers
// ─────────────────────────────────────────────────────────────────────────────

// callHTTP returns a human-readable result line and an error.
// The error is non-nil only on a transport failure (connection refused/reset,
// timeout, TLS handshake failure) — i.e. the egress never completed. An HTTP
// response of any status counts as "the call got through" and returns nil.
func callHTTP(label, url string, tlsCfg *tls.Config) (string, error) {
	transport := &http.Transport{}
	if tlsCfg != nil {
		transport.TLSClientConfig = tlsCfg
	}
	client := &http.Client{Timeout: 5 * time.Second, Transport: transport}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Sprintf("%-22s → ERROR: %v", label, err), err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return fmt.Sprintf("%-22s → HTTP %d: %s", label, resp.StatusCode, strings.TrimSpace(string(body))), nil
}

// callTCP returns a result line and an error. The error is non-nil only when
// the connection itself fails to establish (dial/TLS-handshake) — that is the
// signal that the egress was refused/reset. The PONG read is best-effort: a
// successful dial already proves the egress is permitted, and TCP blocking is
// not exercised by the smoke tests (only /call-blocked, which uses HTTP, is).
func callTCP(label, addr string, tlsCfg *tls.Config) (string, error) {
	var conn net.Conn
	var err error
	if tlsCfg != nil {
		conn, err = tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", addr, tlsCfg)
	} else {
		conn, err = net.DialTimeout("tcp", addr, 5*time.Second)
	}
	if err != nil {
		return fmt.Sprintf("%-22s → ERROR: %v", label, err), err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprint(conn, "PING\n")
	buf := make([]byte, 64)
	n, _ := conn.Read(buf)
	return fmt.Sprintf("%-22s → TCP OK, got: %q", label, strings.TrimSpace(string(buf[:n]))), nil
}

// respond writes a single outbound call's result. On a transport error
// (egress blocked / connection reset) it sets HTTP 502 so a caller can tell a
// blocked egress from a permitted one by status code alone.
func respond(w http.ResponseWriter, result string, err error) {
	w.Header().Set("Content-Type", "text/plain")
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
	}
	fmt.Fprintln(w, result)
}

// ─────────────────────────────────────────────────────────────────────────────
// Echo handler — shows all headers including the injected JWT header
// ─────────────────────────────────────────────────────────────────────────────

func echoHandler(role string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "=== ECHO [%s] ===\n", role)
		fmt.Fprintf(w, "Method : %s\n", r.Method)
		fmt.Fprintf(w, "Path   : %s\n", r.URL.Path)
		fmt.Fprintf(w, "Remote : %s\n\n", r.RemoteAddr)
		fmt.Fprintln(w, "Headers:")
		for k, vs := range r.Header {
			fmt.Fprintf(w, "  %-35s %s\n", k+":", strings.Join(vs, ", "))
		}
		if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
			fmt.Fprintf(w, "\nPeer cert CN: %s\n", r.TLS.PeerCertificates[0].Subject.CommonName)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Role registrations
// ─────────────────────────────────────────────────────────────────────────────

func registerPodA(mux *http.ServeMux, clientTLS *tls.Config) {
	podBAddr := getenv("POD_B_ADDR", "localhost:19080")
	kafkaAddr := getenv("KAFKA_ADDR", "localhost:19092")
	llmAddr := getenv("LLM_ADDR", "localhost:14443")
	blockedAddr := getenv("BLOCKED_ADDR", "localhost:19999")

	scheme := "https"
	if clientTLS == nil {
		scheme = "http"
	}

	mux.HandleFunc("/call-b", func(w http.ResponseWriter, r *http.Request) {
		out, err := callHTTP("pod-a→pod-b", scheme+"://"+podBAddr+"/echo", clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-kafka", func(w http.ResponseWriter, r *http.Request) {
		out, err := callTCP("pod-a→kafka", kafkaAddr, clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-llm", func(w http.ResponseWriter, r *http.Request) {
		out, err := callHTTP("pod-a→llm-gateway", scheme+"://"+llmAddr+"/echo", clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-blocked", func(w http.ResponseWriter, r *http.Request) {
		out, err := callHTTP("pod-a→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-all", func(w http.ResponseWriter, r *http.Request) {
		// Summary endpoint: always 200, individual outcomes printed in the body.
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "=== pod-a outbound summary ===")
		out, _ := callHTTP("pod-a→pod-b", scheme+"://"+podBAddr+"/echo", clientTLS)
		fmt.Fprintln(w, out)
		out, _ = callTCP("pod-a→kafka", kafkaAddr, clientTLS)
		fmt.Fprintln(w, out)
		out, _ = callHTTP("pod-a→llm", scheme+"://"+llmAddr+"/echo", clientTLS)
		fmt.Fprintln(w, out)
		out, _ = callHTTP("pod-a→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS)
		fmt.Fprintln(w, out)
	})
}

func registerPodB(mux *http.ServeMux, clientTLS *tls.Config) {
	kafkaAddr := getenv("KAFKA_ADDR", "localhost:19092")
	stsAddr := getenv("STS_ADDR", "localhost:19093")
	internalAPIAddr := getenv("INTERNAL_API_ADDR", "localhost:19094")
	blockedAddr := getenv("BLOCKED_ADDR", "localhost:19999")

	scheme := "https"
	if clientTLS == nil {
		scheme = "http"
	}

	mux.HandleFunc("/call-kafka", func(w http.ResponseWriter, r *http.Request) {
		out, err := callTCP("pod-b→kafka", kafkaAddr, clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-sts", func(w http.ResponseWriter, r *http.Request) {
		out, err := callHTTP("pod-b→sts", scheme+"://"+stsAddr+"/echo", clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-internal", func(w http.ResponseWriter, r *http.Request) {
		out, err := callHTTP("pod-b→internal-api", scheme+"://"+internalAPIAddr+"/echo", clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-blocked", func(w http.ResponseWriter, r *http.Request) {
		out, err := callHTTP("pod-b→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS)
		respond(w, out, err)
	})
	mux.HandleFunc("/call-all", func(w http.ResponseWriter, r *http.Request) {
		// Summary endpoint: always 200, individual outcomes printed in the body.
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "=== pod-b outbound summary ===")
		out, _ := callTCP("pod-b→kafka", kafkaAddr, clientTLS)
		fmt.Fprintln(w, out)
		out, _ = callHTTP("pod-b→sts", scheme+"://"+stsAddr+"/echo", clientTLS)
		fmt.Fprintln(w, out)
		out, _ = callHTTP("pod-b→internal-api", scheme+"://"+internalAPIAddr+"/echo", clientTLS)
		fmt.Fprintln(w, out)
		out, _ = callHTTP("pod-b→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS)
		fmt.Fprintln(w, out)
	})
}

// ─────────────────────────────────────────────────────────────────────────────
// TCP mock (Kafka simulation)
// ─────────────────────────────────────────────────────────────────────────────

func runTCPMock(tcpPort string, tlsCfg *tls.Config) {
	go func() {
		addr := "127.0.0.1:" + tcpPort
		var ln net.Listener
		var err error
		if tlsCfg != nil {
			ln, err = tls.Listen("tcp", addr, tlsCfg)
			log.Printf("TCP mock listening on %s (TLS/mTLS, loopback only)", addr)
		} else {
			ln, err = net.Listen("tcp", addr)
			log.Printf("TCP mock listening on %s (plain, loopback only)", addr)
		}
		if err != nil {
			log.Printf("TCP mock listen error: %v", err)
			return
		}
		for {
			conn, err := ln.Accept()
			if err != nil {
				continue
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 256)
				n, _ := c.Read(buf)
				fmt.Fprintf(c, "PONG from mock (got %d bytes)\n", n)
			}(conn)
		}
	}()
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

func main() {
	role := getenv("APP_ROLE", "pod-a")
	port := getenv("APP_PORT", "9090")
	tcpPort := getenv("TCP_PORT", "")

	serverTLS := loadServerTLS()
	clientTLS := buildClientTLS()

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"status":"ok","role":%q,"tls":%v}`, role, serverTLS != nil)
	})
	mux.HandleFunc("/echo", echoHandler(role))
	mux.HandleFunc("/", echoHandler(role))

	switch role {
	case "pod-a":
		registerPodA(mux, clientTLS)
	case "pod-b":
		registerPodB(mux, clientTLS)
	case "mock":
		if tcpPort != "" {
			runTCPMock(tcpPort, serverTLS)
		}
	}

	// ── JWT validation middleware ─────────────────────────────────────────────
	// Wrap the mux if a public key is configured.
	// The public key is mounted into the app container from the app-jwt-pubkey
	// secret. The private key (used by Envoy to sign tokens) is NEVER mounted
	// into the app container — only the Envoy sidecar has it.
	var handler http.Handler = mux
	jwtPubkeyFile := getenv("JWT_PUBKEY_FILE", "")
	if jwtPubkeyFile != "" {
		pub := loadRSAPublicKey(jwtPubkeyFile)
		jwtHeader := getenv("JWT_HEADER", "x-envoy-internal-jwt")
		handler = jwtMiddleware(pub, jwtHeader, mux)
		log.Printf("JWT validation ENABLED (header: %s)", jwtHeader)
	} else {
		log.Printf("JWT validation DISABLED (JWT_PUBKEY_FILE not set)")
	}

	log.Printf("testapp starting  role=%s  port=%s  tls=%v", role, port, serverTLS != nil)
	if err := listenAndServe(port, handler, serverTLS); err != nil {
		log.Fatal(err)
	}
}

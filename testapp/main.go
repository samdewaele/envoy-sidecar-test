package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// loadTLSConfig builds a *tls.Config from TLS_CERT / TLS_KEY / TLS_CA env vars.
// Returns nil if the env vars are not set (plain mode — should not happen in
// this stack, but keeps the binary usable standalone).
// When TLS_CA is set, mutual TLS is required: the peer must present a cert
// signed by that CA.
func loadTLSConfig() *tls.Config {
	certFile := getenv("TLS_CERT", "")
	keyFile := getenv("TLS_KEY", "")
	caFile := getenv("TLS_CA", "")

	if certFile == "" || keyFile == "" {
		return nil
	}

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("TLS: failed to load cert/key (%s / %s): %v", certFile, keyFile, err)
	}

	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	if caFile != "" {
		caPEM, err := os.ReadFile(caFile)
		if err != nil {
			log.Fatalf("TLS: failed to read CA %s: %v", caFile, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			log.Fatalf("TLS: failed to parse CA %s", caFile)
		}
		// Require the connecting peer to present a CA-signed cert (mTLS).
		cfg.ClientCAs = caPEM // saved for TCP server below
		cfg.ClientAuth = tls.RequireAndVerifyClientCert
		cfg.ClientCAs = nil // reset; set properly below
		cfg.RootCAs = pool  // used when this binary is the client (outbound)
		// For server mode:
		serverCfg := cfg.Clone()
		serverCfg.ClientCAs = pool
		serverCfg.ClientAuth = tls.RequireAndVerifyClientCert
		return serverCfg
	}

	return cfg
}

// listenAndServe starts an HTTP(S) server.
// IMPORTANT: always binds to 127.0.0.1 (loopback only).
// The app must never be reachable directly from the pod network — all
// inbound traffic must arrive through the Envoy sidecar on port 8443.
func listenAndServe(port string, handler http.Handler, tlsCfg *tls.Config) error {
	addr := "127.0.0.1:" + port
	if tlsCfg != nil {
		ln, err := tls.Listen("tcp", addr, tlsCfg)
		if err != nil {
			return err
		}
		log.Printf("listening on %s (HTTPS/mTLS, loopback only)", addr)
		return http.Serve(ln, handler)
	}
	log.Printf("listening on %s (HTTP, loopback only)", addr)
	return http.ListenAndServe(addr, handler)
}

// callHTTP performs a GET, optionally with a client cert for mTLS.
func callHTTP(label, url string, tlsCfg *tls.Config) string {
	transport := &http.Transport{}
	if tlsCfg != nil {
		transport.TLSClientConfig = tlsCfg
	}
	client := &http.Client{Timeout: 5 * time.Second, Transport: transport}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Sprintf("%-22s → ERROR: %v", label, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return fmt.Sprintf("%-22s → HTTP %d: %s", label, resp.StatusCode, strings.TrimSpace(string(body)))
}

// callTCP opens a TLS TCP connection, writes a ping, reads a line.
func callTCP(label, addr string, tlsCfg *tls.Config) string {
	var conn net.Conn
	var err error
	if tlsCfg != nil {
		conn, err = tls.DialWithDialer(
			&net.Dialer{Timeout: 5 * time.Second},
			"tcp", addr, tlsCfg,
		)
	} else {
		conn, err = net.DialTimeout("tcp", addr, 5*time.Second)
	}
	if err != nil {
		return fmt.Sprintf("%-22s → ERROR: %v", label, err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprint(conn, "PING\n")
	buf := make([]byte, 64)
	n, _ := conn.Read(buf)
	return fmt.Sprintf("%-22s → TCP OK, got: %q", label, strings.TrimSpace(string(buf[:n])))
}

// echoHandler returns the request method, path, remote addr, and all headers.
// Useful for verifying that X-SSL-Client-CN arrives end-to-end.
func echoHandler(role string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "=== ECHO [%s] ===\n", role)
		fmt.Fprintf(w, "Method : %s\n", r.Method)
		fmt.Fprintf(w, "Path   : %s\n", r.URL.Path)
		fmt.Fprintf(w, "Remote : %s\n\n", r.RemoteAddr)
		fmt.Fprintln(w, "Headers:")
		for k, vs := range r.Header {
			fmt.Fprintf(w, "  %-30s %s\n", k+":", strings.Join(vs, ", "))
		}
		// Show mTLS peer CN if the connection carried a client cert.
		if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
			fmt.Fprintf(w, "\nPeer cert CN : %s\n", r.TLS.PeerCertificates[0].Subject.CommonName)
		}
	}
}

// buildClientTLS builds a *tls.Config suitable for outbound HTTP/TCP calls
// (presents the app's own cert + verifies the server against the CA).
func buildClientTLS() *tls.Config {
	certFile := getenv("TLS_CERT", "")
	keyFile := getenv("TLS_KEY", "")
	caFile := getenv("TLS_CA", "")
	if certFile == "" || keyFile == "" || caFile == "" {
		return nil
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("TLS: client cert load error: %v", err)
	}
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		log.Fatalf("TLS: CA read error: %v", err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      pool,
		MinVersion:   tls.VersionTLS12,
	}
}

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
		fmt.Fprintln(w, callHTTP("pod-a→pod-b", scheme+"://"+podBAddr+"/echo", clientTLS))
	})
	mux.HandleFunc("/call-kafka", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, callTCP("pod-a→kafka", kafkaAddr, clientTLS))
	})
	mux.HandleFunc("/call-llm", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, callHTTP("pod-a→llm-gateway", scheme+"://"+llmAddr+"/echo", clientTLS))
	})
	// /call-blocked: hits the Envoy "forbidden" listener.
	// DEV → passes through; QA → logged; PROD → connection reset.
	mux.HandleFunc("/call-blocked", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, callHTTP("pod-a→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS))
	})
	mux.HandleFunc("/call-all", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "=== pod-a outbound summary ===")
		fmt.Fprintln(w, callHTTP("pod-a→pod-b", scheme+"://"+podBAddr+"/echo", clientTLS))
		fmt.Fprintln(w, callTCP("pod-a→kafka", kafkaAddr, clientTLS))
		fmt.Fprintln(w, callHTTP("pod-a→llm", scheme+"://"+llmAddr+"/echo", clientTLS))
		fmt.Fprintln(w, callHTTP("pod-a→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS))
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
		fmt.Fprintln(w, callTCP("pod-b→kafka", kafkaAddr, clientTLS))
	})
	mux.HandleFunc("/call-sts", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, callHTTP("pod-b→sts", scheme+"://"+stsAddr+"/echo", clientTLS))
	})
	mux.HandleFunc("/call-internal", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, callHTTP("pod-b→internal-api", scheme+"://"+internalAPIAddr+"/echo", clientTLS))
	})
	mux.HandleFunc("/call-blocked", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, callHTTP("pod-b→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS))
	})
	mux.HandleFunc("/call-all", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "=== pod-b outbound summary ===")
		fmt.Fprintln(w, callTCP("pod-b→kafka", kafkaAddr, clientTLS))
		fmt.Fprintln(w, callHTTP("pod-b→sts", scheme+"://"+stsAddr+"/echo", clientTLS))
		fmt.Fprintln(w, callHTTP("pod-b→internal-api", scheme+"://"+internalAPIAddr+"/echo", clientTLS))
		fmt.Fprintln(w, callHTTP("pod-b→BLOCKED", scheme+"://"+blockedAddr+"/echo", clientTLS))
	})
}

// runTCPMock starts a TLS (or plain) TCP echo server for the Kafka mock.
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

func main() {
	role := getenv("APP_ROLE", "pod-a")
	port := getenv("APP_PORT", "9090")
	tcpPort := getenv("TCP_PORT", "")

	// Server TLS config (for inbound connections to this binary)
	serverTLS := loadTLSConfig()
	// Client TLS config (for outbound calls this binary makes)
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

	log.Printf("testapp starting  role=%s  port=%s  tls=%v", role, port, serverTLS != nil)
	if err := listenAndServe(port, mux, serverTLS); err != nil {
		log.Fatal(err)
	}
}

package main

import (
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

// callHTTP performs a GET to url and returns a short result string.
func callHTTP(label, url string) string {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Sprintf("%-20s → ERROR: %v", label, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return fmt.Sprintf("%-20s → HTTP %d: %s", label, resp.StatusCode, strings.TrimSpace(string(body)))
}

// callTCP opens a TCP connection, writes a ping, reads a line, closes.
func callTCP(label, addr string) string {
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return fmt.Sprintf("%-20s → ERROR: %v", label, err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprint(conn, "PING\n")
	buf := make([]byte, 64)
	n, _ := conn.Read(buf)
	return fmt.Sprintf("%-20s → TCP OK, got: %q", label, strings.TrimSpace(string(buf[:n])))
}

// echoHandler shows everything Envoy passes through — handy for debugging headers.
func echoHandler(role string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "=== ECHO [%s] ===\n", role)
		fmt.Fprintf(w, "Method : %s\n", r.Method)
		fmt.Fprintf(w, "Path   : %s\n", r.URL.Path)
		fmt.Fprintf(w, "Remote : %s\n\n", r.RemoteAddr)
		fmt.Fprintf(w, "Headers:\n")
		for k, vs := range r.Header {
			fmt.Fprintf(w, "  %-30s %s\n", k+":", strings.Join(vs, ", "))
		}
	}
}

func registerPodA(mux *http.ServeMux) {
	podBAddr := getenv("POD_B_ADDR", "localhost:19080")
	kafkaAddr := getenv("KAFKA_ADDR", "localhost:19092")
	llmAddr := getenv("LLM_ADDR", "localhost:14443")
	blockedAddr := getenv("BLOCKED_ADDR", "localhost:19999")

	mux.HandleFunc("/call-b", func(w http.ResponseWriter, r *http.Request) {
		result := callHTTP("pod-a→pod-b", "http://"+podBAddr+"/echo")
		fmt.Fprintln(w, result)
	})
	mux.HandleFunc("/call-kafka", func(w http.ResponseWriter, r *http.Request) {
		result := callTCP("pod-a→kafka", kafkaAddr)
		fmt.Fprintln(w, result)
	})
	mux.HandleFunc("/call-llm", func(w http.ResponseWriter, r *http.Request) {
		result := callHTTP("pod-a→llm-gateway", "http://"+llmAddr+"/echo")
		fmt.Fprintln(w, result)
	})
	// /call-blocked hits a target that is NOT in the whitelist.
	// DEV  → passes through (mock responds)
	// QA   → Envoy logs [WHITELIST-VIOLATION] but forwards
	// PROD → Envoy closes the connection immediately
	mux.HandleFunc("/call-blocked", func(w http.ResponseWriter, r *http.Request) {
		result := callHTTP("pod-a→BLOCKED", "http://"+blockedAddr+"/echo")
		fmt.Fprintln(w, result)
	})
	// /call-all fires every upstream and returns a summary — handy for smoke tests.
	mux.HandleFunc("/call-all", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "=== pod-a outbound summary ===")
		fmt.Fprintln(w, callHTTP("pod-a→pod-b", "http://"+podBAddr+"/echo"))
		fmt.Fprintln(w, callTCP("pod-a→kafka", kafkaAddr))
		fmt.Fprintln(w, callHTTP("pod-a→llm", "http://"+llmAddr+"/echo"))
		fmt.Fprintln(w, callHTTP("pod-a→BLOCKED", "http://"+blockedAddr+"/echo"))
	})
}

func registerPodB(mux *http.ServeMux) {
	kafkaAddr := getenv("KAFKA_ADDR", "localhost:19092")
	stsAddr := getenv("STS_ADDR", "localhost:19093")
	internalAPIAddr := getenv("INTERNAL_API_ADDR", "localhost:19094")
	blockedAddr := getenv("BLOCKED_ADDR", "localhost:19999")

	mux.HandleFunc("/call-kafka", func(w http.ResponseWriter, r *http.Request) {
		result := callTCP("pod-b→kafka", kafkaAddr)
		fmt.Fprintln(w, result)
	})
	mux.HandleFunc("/call-sts", func(w http.ResponseWriter, r *http.Request) {
		result := callHTTP("pod-b→sts", "http://"+stsAddr+"/echo")
		fmt.Fprintln(w, result)
	})
	mux.HandleFunc("/call-internal", func(w http.ResponseWriter, r *http.Request) {
		result := callHTTP("pod-b→internal-api", "http://"+internalAPIAddr+"/echo")
		fmt.Fprintln(w, result)
	})
	mux.HandleFunc("/call-blocked", func(w http.ResponseWriter, r *http.Request) {
		result := callHTTP("pod-b→BLOCKED", "http://"+blockedAddr+"/echo")
		fmt.Fprintln(w, result)
	})
	mux.HandleFunc("/call-all", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "=== pod-b outbound summary ===")
		fmt.Fprintln(w, callTCP("pod-b→kafka", kafkaAddr))
		fmt.Fprintln(w, callHTTP("pod-b→sts", "http://"+stsAddr+"/echo"))
		fmt.Fprintln(w, callHTTP("pod-b→internal-api", "http://"+internalAPIAddr+"/echo"))
		fmt.Fprintln(w, callHTTP("pod-b→BLOCKED", "http://"+blockedAddr+"/echo"))
	})
}

// mock role: TCP echo server + HTTP echo handler on the same binary.
// Used for kafka-mock (TCP), and all HTTP mock targets.
func runMock(port, tcpPort string) {
	// TCP echo for kafka mock
	if tcpPort != "" {
		go func() {
			ln, err := net.Listen("tcp", ":"+tcpPort)
			if err != nil {
				log.Printf("TCP mock listen error: %v", err)
				return
			}
			log.Printf("TCP mock listening on :%s", tcpPort)
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
}

func main() {
	role := getenv("APP_ROLE", "pod-a")
	port := getenv("APP_PORT", "9090")
	tcpPort := getenv("TCP_PORT", "") // only used by mock role

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"status":"ok","role":%q}`, role)
	})
	mux.HandleFunc("/echo", echoHandler(role))
	mux.HandleFunc("/", echoHandler(role)) // catch-all for mock targets

	switch role {
	case "pod-a":
		registerPodA(mux)
	case "pod-b":
		registerPodB(mux)
	case "mock":
		runMock(port, tcpPort)
	}

	log.Printf("testapp starting  role=%s  http=:%s", role, port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

#!/usr/bin/env bash
# =============================================================================
# probe.sh — connectivity matrix for a locally-deployed stack.
#
# Exercises every connection, both the ones that MUST work and the ones that
# MUST be blocked, and prints a pass/fail table. A "pass" means the observed
# behaviour matched the expectation (ALLOW or DENY), so a correctly-blocked
# connection is a ✅, not a ❌.
#
# Modes:
#   ./scripts/probe.sh            one-shot: inbound + egress + NetworkPolicy,
#                                 prints a summary and exits non-zero on mismatch
#                                 (used by CI).
#   ./scripts/probe.sh watch [s]  live: re-runs the request matrix every [s]
#                                 seconds (default 5) as a refreshing dashboard.
#                                 Ctrl-C to stop. Skips the slow netpol timeout
#                                 checks so the cadence stays tight.
# =============================================================================
set -uo pipefail

MODE=oneshot
INTERVAL=5
if [ "${1:-}" = "watch" ]; then MODE=watch; INTERVAL="${2:-5}"; fi

NS_CLIENT=client
NS_APPS=apps
F5=https://f5-sim.f5.svc.cluster.local
CERTS="--cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt"

pass=0; fail=0
report() {  # <expected> <actual> <description>
  if [ "$1" = "$2" ]; then
    printf "  \033[32m✅\033[0m %-48s %s\n" "$3" "($2)"; pass=$((pass+1))
  else
    printf "  \033[31m❌\033[0m %-48s expected %s, got %s\n" "$3" "$1" "$2"; fail=$((fail+1))
  fi
}

# client → f5 (full ingress chain) with a valid client cert
ca()        { kubectl exec -n "$NS_CLIENT" client -- curl -sf --max-time 8 $CERTS "$1" >/dev/null 2>&1 && echo ALLOW || echo DENY; }
# client → f5 WITHOUT a client cert (must fail the mTLS handshake)
ca_nocert() { kubectl exec -n "$NS_CLIENT" client -- curl -sf --max-time 8 --cacert /certs/ca.crt "$1" >/dev/null 2>&1 && echo ALLOW || echo DENY; }
# exec into Pod B app, curl an HTTP egress port (→ sidecar → gateway → upstream)
pb_http()   { kubectl exec -n "$NS_APPS" "$1" -c app -- curl -sf --max-time 8 "http://localhost:$2/echo" >/dev/null 2>&1 && echo ALLOW || echo DENY; }
# TCP egress probe (kafka): hold the connection open (sleep) so the echo reply
# returns before nc closes on stdin EOF; ALLOW only if PONG round-trips.
tcp_ping()  { kubectl exec -n "$NS_APPS" "$1" -c app -- sh -c "{ printf 'PING\n'; sleep 3; } | nc -w 5 localhost $2 2>/dev/null" 2>/dev/null | grep -q PONG && echo ALLOW || echo DENY; }
# exec into Pod A app, reach a destination DIRECTLY (bypassing the gateway);
# NetworkPolicy should silently drop it → curl times out (exit 28) → DROPPED
np_direct() { kubectl exec -n "$NS_APPS" "$1" -c app -- curl -s --max-time 6 -o /dev/null "$2" >/dev/null 2>&1; [ $? -eq 28 ] && echo DROPPED || echo REACHED; }

podname() { kubectl get pod -n "$NS_APPS" -l "app=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# ── the request matrix (inbound + egress); fast, safe to loop ─────────────────
run_requests() {
  local pod_b; pod_b=$(podname pod-b)
  echo "── INBOUND — sidecar mTLS + CN whitelist (Pod A) ─────────────────"
  report ALLOW "$(ca        "$F5/health")" "client WITH valid cert → pod-a /health"
  report DENY  "$(ca_nocert "$F5/health")" "client WITHOUT cert    → pod-a /health"
  echo "── POD A EGRESS — via gateway, authorized by CN=pod-a ────────────"
  report ALLOW "$(ca "$F5/call-b")"        "pod-a → pod-b        (direct east-west)"
  report ALLOW "$(ca "$F5/call-kafka")"    "pod-a → kafka        (gateway)"
  report ALLOW "$(ca "$F5/call-llm")"      "pod-a → llm-gateway  (gateway)"
  report DENY  "$(ca "$F5/call-internal")" "pod-a → internal-api (CN not authorized)"
  report DENY  "$(ca "$F5/call-blocked")"  "pod-a → blocked      (no route)"
  echo "── POD B EGRESS — via gateway, authorized by CN=pod-b ────────────"
  report ALLOW "$(tcp_ping "$pod_b" 19092)" "pod-b → kafka        (gateway, PONG round-trip)"
  report ALLOW "$(pb_http  "$pod_b" 19094)" "pod-b → internal-api (gateway)"
  report DENY  "$(pb_http  "$pod_b" 14443)" "pod-b → llm-gateway  (CN not authorized)"
  report DENY  "$(pb_http  "$pod_b" 19999)" "pod-b → blocked      (no route)"
}

# ── kernel-level NetworkPolicy checks (slow: rely on connect timeouts) ────────
run_netpol() {
  local pod_a; pod_a=$(podname pod-a)
  echo "── NETWORKPOLICY — pods cannot reach upstreams directly ──────────"
  report DROPPED "$(np_direct "$pod_a" http://kafka-mock.kafka.svc.cluster.local:9092/)"          "pod-a → kafka-mock        DIRECT (kernel drop)"
  report DROPPED "$(np_direct "$pod_a" http://internal-api-mock.internal-api.svc.cluster.local:8080/)" "pod-a → internal-api-mock DIRECT (kernel drop)"
}

warmup() { for i in $(seq 1 15); do ca "$F5/call-kafka" | grep -q ALLOW && break; sleep 2; done; }

if [ -z "$(podname pod-a)" ] || [ -z "$(podname pod-b)" ]; then
  echo "❌  pod-a / pod-b not found in namespace '$NS_APPS' — is the stack deployed?"
  exit 1
fi

# ── watch mode ────────────────────────────────────────────────────────────────
if [ "$MODE" = "watch" ]; then
  trap 'echo; echo "stopped."; exit 0' INT
  echo "▶  warming up..."; warmup
  n=0
  while true; do
    n=$((n+1)); pass=0; fail=0
    printf '\033[H\033[2J'   # home + clear
    echo "═══ connectivity probe — iteration $n — $(date '+%H:%M:%S') — every ${INTERVAL}s (Ctrl-C to stop) ═══"
    echo ""
    run_requests
    echo ""
    printf "  %s ok / %s mismatched\n" "$pass" "$fail"
    sleep "$INTERVAL"
  done
fi

# ── one-shot mode ───────────────────────────────────────────────────────────
echo "▶  warming up ingress chain + gateway..."; warmup
echo ""
run_requests
echo ""
run_netpol
echo ""
echo "══════════════════════════════════════════════════════════════════════"
printf "  %s passed, %s failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]

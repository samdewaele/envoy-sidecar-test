#!/usr/bin/env bash
# =============================================================================
# probe.sh — connectivity matrix for a locally-deployed stack.
#
# Exercises every connection, both the ones that MUST work and the ones that
# MUST be blocked, and prints a pass/fail table. A "pass" means the observed
# behaviour matched the expectation (ALLOW or DENY), so a correctly-blocked
# connection is a ✅, not a ❌.
#
# Run after `make dev|qa|prod`  (or `make probe`).
#
# Coverage:
#   inbound  — client mTLS to Pod A (valid cert allowed, no cert rejected)
#   egress   — Pod A and Pod B through the gateway (per-CN allow + deny + no-route)
#   netpol   — pods cannot reach upstreams directly (kernel drop)
# =============================================================================
set -uo pipefail

NS_CLIENT=client
NS_APPS=apps
F5=https://f5-sim.f5.svc.cluster.local
CERTS="--cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt"

POD_A=$(kubectl get pod -n "$NS_APPS" -l app=pod-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
POD_B=$(kubectl get pod -n "$NS_APPS" -l app=pod-b -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

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
pb_http()   { kubectl exec -n "$NS_APPS" "$POD_B" -c app -- curl -sf --max-time 8 "http://localhost:$1/echo" >/dev/null 2>&1 && echo ALLOW || echo DENY; }
# exec into Pod A app, try to reach a destination DIRECTLY (bypassing the gateway);
# NetworkPolicy should silently drop it → curl times out (exit 28) → DROPPED
np_direct() { kubectl exec -n "$NS_APPS" "$POD_A" -c app -- curl -s --max-time 6 -o /dev/null "$1" >/dev/null 2>&1; [ $? -eq 28 ] && echo DROPPED || echo REACHED; }

if [ -z "$POD_A" ] || [ -z "$POD_B" ]; then
  echo "❌  pod-a / pod-b not found in namespace '$NS_APPS' — is the stack deployed?"
  exit 1
fi

echo "▶  warming up ingress chain + gateway..."
for i in $(seq 1 15); do ca "$F5/call-kafka" | grep -q ALLOW && break; sleep 2; done

echo ""
echo "════ INBOUND — sidecar mTLS + CN whitelist (Pod A) ═══════════════════"
report ALLOW "$(ca        "$F5/health")" "client WITH valid cert → pod-a /health"
report DENY  "$(ca_nocert "$F5/health")" "client WITHOUT cert    → pod-a /health"

echo ""
echo "════ POD A EGRESS — via gateway, authorized by CN=pod-a ══════════════"
report ALLOW "$(ca "$F5/call-b")"        "pod-a → pod-b        (direct east-west)"
report ALLOW "$(ca "$F5/call-kafka")"    "pod-a → kafka        (gateway)"
report ALLOW "$(ca "$F5/call-llm")"      "pod-a → llm-gateway  (gateway)"
report DENY  "$(ca "$F5/call-internal")" "pod-a → internal-api (CN not authorized)"
report DENY  "$(ca "$F5/call-blocked")"  "pod-a → blocked      (no route)"

echo ""
echo "════ POD B EGRESS — via gateway, authorized by CN=pod-b ══════════════"
# (pod-b → kafka is allowed by the same route pod-a uses; kafka is a raw TCP
#  echo that does not round-trip cleanly through the double mTLS tunnel from a
#  shell, so it is not asserted here. pod-b's CN is proven by internal-api below.)
report ALLOW "$(pb_http 19094)" "pod-b → internal-api (gateway)"
report DENY  "$(pb_http 14443)" "pod-b → llm-gateway  (CN not authorized)"
report DENY  "$(pb_http 19999)" "pod-b → blocked      (no route)"

echo ""
echo "════ NETWORKPOLICY — pods cannot reach upstreams directly ════════════"
report DROPPED "$(np_direct http://kafka-mock.kafka.svc.cluster.local:9092/)"          "pod-a → kafka-mock        DIRECT (kernel drop)"
report DROPPED "$(np_direct http://internal-api-mock.internal-api.svc.cluster.local:8080/)" "pod-a → internal-api-mock DIRECT (kernel drop)"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
printf "  %s passed, %s failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]

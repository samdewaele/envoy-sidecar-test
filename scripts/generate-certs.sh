#!/usr/bin/env bash
# =============================================================================
# generate-certs.sh
#
# Self-signed CA + leaf certs for the multi-namespace gateway topology, plus an
# RS256 JWT keypair. Creates every namespace and distributes the secrets.
#
# Leaf certs (all signed by one CA):
#   test-client   client identity to f5-sim
#   f5-sim        f5-sim server cert
#   haproxy       haproxy identity (bundled as haproxy.pem)
#   pod-a         Pod A sidecar identity  (CN=pod-a — gateway authorizes by this)
#   pod-b         Pod B sidecar identity  (CN=pod-b)
#   gateway       egress gateway identity (CN=gateway)
#   mock-target   shared cert for all mock targets (SANs across their namespaces)
# =============================================================================
set -euo pipefail

OUT="certs"
DOMAIN="cluster.local"
mkdir -p "$OUT"

# Namespaces — MUST match helm/values.yaml .namespaces
NS_F5=f5
NS_HAPROXY=haproxy
NS_APPS=apps
NS_GATEWAY=gateway
NS_CLIENT=client
NS_KAFKA=kafka
NS_INTERNAL=internal-api
NS_LLM=llm-gateway
NS_BLOCKED=blocked
ALL_NS="$NS_F5 $NS_HAPROXY $NS_APPS $NS_GATEWAY $NS_CLIENT $NS_KAFKA $NS_INTERNAL $NS_LLM $NS_BLOCKED"

echo "▶  Generating certificates in ./$OUT"

# ── CA ────────────────────────────────────────────────────────────────────────
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
  -keyout "$OUT/ca.key" -out "$OUT/ca.crt" \
  -subj "/CN=envoy-test-ca/O=TestOrg" 2>/dev/null
echo "   CA generated"

# ── issue_cert <cn> <prefix> <subjectAltName> ─────────────────────────────────
issue_cert() {
  local cn="$1" pfx="$2" san="$3"
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$OUT/${pfx}.key" -out "$OUT/${pfx}.csr" \
    -subj "/CN=${cn}/O=TestOrg" 2>/dev/null
  openssl x509 -req -days 825 \
    -in "$OUT/${pfx}.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
    -out "$OUT/${pfx}.crt" -extfile <(printf "subjectAltName=%s" "$san") 2>/dev/null
  rm "$OUT/${pfx}.csr"
  echo "   issued: CN=${cn}  →  ${pfx}.crt"
}

issue_cert "test-client" "client"  "DNS:test-client,DNS:localhost"
issue_cert "f5-sim"      "f5-sim"   "DNS:f5-sim,DNS:f5-sim.${NS_F5}.svc.${DOMAIN},DNS:localhost"
issue_cert "haproxy"     "haproxy"  "DNS:haproxy,DNS:haproxy.${NS_HAPROXY}.svc.${DOMAIN},DNS:localhost"
# Pod identity certs — first DNS SAN is the bare name the gateway RBAC matches on.
issue_cert "pod-a"       "pod-a"    "DNS:pod-a,DNS:pod-a-service.${NS_APPS}.svc.${DOMAIN},DNS:localhost"
issue_cert "pod-b"       "pod-b"    "DNS:pod-b,DNS:pod-b-service.${NS_APPS}.svc.${DOMAIN},DNS:localhost"
# Gateway cert — service DNS plus the SNI routing tokens (harmless extra SANs).
issue_cert "gateway"     "gateway"  "DNS:gateway,DNS:gateway.${NS_GATEWAY}.svc.${DOMAIN},DNS:kafka,DNS:llm-gateway,DNS:internal-api,DNS:localhost"
# Mock cert — all mock service DNS names across their namespaces.
issue_cert "mock-target" "mock" \
  "DNS:mock-target,DNS:kafka-mock,DNS:kafka-mock.${NS_KAFKA}.svc.${DOMAIN},DNS:llm-gateway-mock,DNS:llm-gateway-mock.${NS_LLM}.svc.${DOMAIN},DNS:internal-api-mock,DNS:internal-api-mock.${NS_INTERNAL}.svc.${DOMAIN},DNS:blocked-mock,DNS:blocked-mock.${NS_BLOCKED}.svc.${DOMAIN},DNS:localhost"

# HAProxy needs cert+key as one PEM bundle
cat "$OUT/haproxy.crt" "$OUT/haproxy.key" > "$OUT/haproxy.pem"

# ── JWT RS256 keypair + pre-signed token ──────────────────────────────────────
echo "▶  Generating JWT RS256 keypair + token"
openssl genrsa -out "$OUT/jwt.key" 2048 2>/dev/null
openssl rsa -in "$OUT/jwt.key" -pubout -out "$OUT/jwt.pub" 2>/dev/null
b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
HDR=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
EXP=$(( $(date +%s) + 3153600000 ))
PAY=$(printf '%s' "{\"iss\":\"envoy-sidecar\",\"sub\":\"envoy-internal\",\"exp\":${EXP}}" | b64url)
SIG=$(printf '%s' "${HDR}.${PAY}" | openssl dgst -sha256 -sign "$OUT/jwt.key" -binary | b64url)
printf '%s' "${HDR}.${PAY}.${SIG}" > "$OUT/jwt.token"

# ── Namespaces ─────────────────────────────────────────────────────────────────
echo ""
echo "▶  Creating namespaces"
for ns in $ALL_NS; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
done

# ── Secret helpers ──────────────────────────────────────────────────────────────
mk_tls_secret() {  # <secret> <namespace> <cert-prefix>
  kubectl create secret generic "$1" --namespace="$2" \
    --from-file=tls.crt="$OUT/$3.crt" \
    --from-file=tls.key="$OUT/$3.key" \
    --from-file=ca.crt="$OUT/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -
}

echo ""
echo "▶  Loading secrets"

mk_tls_secret f5-sim-certs       "$NS_F5"       f5-sim
mk_tls_secret envoy-certs-pod-a  "$NS_APPS"     pod-a
mk_tls_secret envoy-certs-pod-b  "$NS_APPS"     pod-b
mk_tls_secret gateway-certs      "$NS_GATEWAY"  gateway

# mock cert is shared across all four mock namespaces
mk_tls_secret mock-certs "$NS_KAFKA"    mock
mk_tls_secret mock-certs "$NS_LLM"      mock
mk_tls_secret mock-certs "$NS_INTERNAL" mock
mk_tls_secret mock-certs "$NS_BLOCKED"  mock

# haproxy: PEM bundle + CA
kubectl create secret generic haproxy-certs --namespace="$NS_HAPROXY" \
  --from-file=haproxy.pem="$OUT/haproxy.pem" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# client: client.crt/key/ca
kubectl create secret generic client-certs --namespace="$NS_CLIENT" \
  --from-file=client.crt="$OUT/client.crt" \
  --from-file=client.key="$OUT/client.key" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# JWT: private token in the apps namespace (Envoy reads it), public key likewise (app verifies)
kubectl create secret generic envoy-jwt-token --namespace="$NS_APPS" \
  --from-file=jwt.token="$OUT/jwt.token" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic app-jwt-pubkey --namespace="$NS_APPS" \
  --from-file=jwt.pub="$OUT/jwt.pub" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✅  Done. Namespaces and secrets created."

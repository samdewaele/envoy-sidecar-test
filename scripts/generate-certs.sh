#!/usr/bin/env bash
# =============================================================================
# generate-certs.sh
#
# Generates a self-signed CA and the leaf certificates needed by the toy stack:
#
#   CN=test-client  →  client.crt / client.key
#                      Presented by the test-client pod to f5-sim (the "external
#                      client" in the mTLS handshake).
#
#   CN=f5-sim       →  f5-sim.crt / f5-sim.key
#                      f5-sim's own TLS identity (the server cert the client sees).
#
#   CN=haproxy      →  haproxy.crt / haproxy.key  → haproxy.pem (combined)
#                      HAProxy presents this to Pod A's Envoy during re-encrypt.
#
#   CN=pod-a        →  pod-a.crt / pod-a.key
#                      Pod A's Envoy identity — presented to Pod B during mTLS.
#
#   CN=pod-b        →  pod-b.crt / pod-b.key
#                      Pod B's Envoy identity.
#
# All certs are signed by the same CA so the whole chain trusts each other.
#
# Usage:
#   ./scripts/generate-certs.sh [namespace]
#   namespace defaults to "envoy-test"
# =============================================================================
set -euo pipefail

NS="${1:-envoy-test}"
OUT="certs"
mkdir -p "$OUT"

echo "▶  Generating certificates in ./$OUT  (namespace: $NS)"

# ── CA ────────────────────────────────────────────────────────────────────────
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
  -keyout "$OUT/ca.key" \
  -out    "$OUT/ca.crt" \
  -subj   "/CN=envoy-test-ca/O=TestOrg"
echo "   CA generated"

# ── Helper: issue_cert <cn> <san_dns> <prefix> ────────────────────────────────
issue_cert() {
  local cn="$1"
  local san="$2"   # additional SAN DNS name (can be same as cn)
  local pfx="$3"

  openssl req -newkey rsa:2048 -nodes \
    -keyout "$OUT/${pfx}.key" \
    -out    "$OUT/${pfx}.csr" \
    -subj   "/CN=${cn}/O=TestOrg"

  openssl x509 -req -days 825 \
    -in      "$OUT/${pfx}.csr" \
    -CA      "$OUT/ca.crt" \
    -CAkey   "$OUT/ca.key" \
    -CAcreateserial \
    -out     "$OUT/${pfx}.crt" \
    -extfile <(printf "subjectAltName=DNS:%s,DNS:%s,DNS:localhost" "$cn" "$san")

  rm "$OUT/${pfx}.csr"
  echo "   issued: CN=${cn}  SAN=${san}  →  ${pfx}.crt"
}

# ── Leaf certificates ─────────────────────────────────────────────────────────
#
# test-client: the external caller that connects to f5-sim with a client cert.
issue_cert "test-client" "test-client" "client"

# f5-sim: the nginx pod presenting a server cert to the external client.
issue_cert "f5-sim" "f5-sim.envoy-test.svc.cluster.local" "f5-sim"

# haproxy: HAProxy presents this to Pod A's Envoy during the TLS re-encrypt.
issue_cert "haproxy"  "haproxy.envoy-test.svc.cluster.local"  "haproxy"

# pod-a: Envoy sidecar in Pod A. Presented to Pod B's Envoy over mTLS.
issue_cert "pod-a" "pod-a-service.envoy-test.svc.cluster.local" "pod-a"

# pod-b: Envoy sidecar in Pod B.
issue_cert "pod-b" "pod-b-service.envoy-test.svc.cluster.local" "pod-b"

# mock-target: shared cert for all mock target pods (kafka, llm-gateway, sts,
# internal-api, blocked). All their service DNS names are listed as SANs so
# Envoy's upstream TLS verification passes regardless of which mock it connects to.
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/mock.key" \
  -out    "$OUT/mock.csr" \
  -subj   "/CN=mock-target/O=TestOrg"

openssl x509 -req -days 825 \
  -in      "$OUT/mock.csr" \
  -CA      "$OUT/ca.crt" \
  -CAkey   "$OUT/ca.key" \
  -CAcreateserial \
  -out     "$OUT/mock.crt" \
  -extfile <(printf "subjectAltName=DNS:mock-target,DNS:kafka-mock,DNS:kafka-mock.envoy-test.svc.cluster.local,DNS:llm-gateway-mock,DNS:llm-gateway-mock.envoy-test.svc.cluster.local,DNS:sts-mock,DNS:sts-mock.envoy-test.svc.cluster.local,DNS:internal-api-mock,DNS:internal-api-mock.envoy-test.svc.cluster.local,DNS:blocked-mock,DNS:blocked-mock.envoy-test.svc.cluster.local,DNS:localhost")

rm "$OUT/mock.csr"
echo "   issued: CN=mock-target (all mock service SANs)  →  mock.crt"

# HAProxy needs cert+key as a single PEM bundle
cat "$OUT/haproxy.crt" "$OUT/haproxy.key" > "$OUT/haproxy.pem"

echo ""
echo "▶  Loading Kubernetes secrets into namespace: $NS"


kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

# ── f5-sim-certs ─────────────────────────────────────────────────────────────
# f5-sim needs its own server cert + CA to verify client certs
kubectl create secret generic f5-sim-certs \
  --namespace="$NS" \
  --from-file=tls.crt="$OUT/f5-sim.crt" \
  --from-file=tls.key="$OUT/f5-sim.key" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── haproxy-certs ─────────────────────────────────────────────────────────────
# HAProxy needs its combined PEM + CA to verify Pod A's Envoy cert
kubectl create secret generic haproxy-certs \
  --namespace="$NS" \
  --from-file=haproxy.pem="$OUT/haproxy.pem" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── envoy-certs ───────────────────────────────────────────────────────────────
# Envoy sidecars in both pods share this secret for simplicity.
# In production: issue separate certs per pod (different CN / SAN).
# Pod A's cert is used here; swap pod-b.crt/key for the Pod B deployment
# if you want distinct identities per pod.
kubectl create secret generic envoy-certs \
  --namespace="$NS" \
  --from-file=tls.crt="$OUT/pod-a.crt" \
  --from-file=tls.key="$OUT/pod-a.key" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── client-certs ─────────────────────────────────────────────────────────────
# The test-client pod uses these to authenticate to f5-sim
kubectl create secret generic client-certs \
  --namespace="$NS" \
  --from-file=client.crt="$OUT/client.crt" \
  --from-file=client.key="$OUT/client.key" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── mock-certs ────────────────────────────────────────────────────────────────
# Shared by all mock target pods (kafka-mock, llm-gateway-mock, sts-mock,
# internal-api-mock, blocked-mock). Envoy verifies this cert against the CA
# when making outbound TLS connections to those targets.
kubectl create secret generic mock-certs \
  --namespace="$NS" \
  --from-file=tls.crt="$OUT/mock.crt" \
  --from-file=tls.key="$OUT/mock.key" \
  --from-file=ca.crt="$OUT/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── JWT RS256 keypair + pre-signed token ──────────────────────────────────────
#
# Private key → mounted ONLY in the Envoy sidecar (envoy-jwt-token secret).
# Public  key → mounted ONLY in the app container  (app-jwt-pubkey  secret).
#
# The Lua filter in Envoy reads the token from /jwt/jwt.token and injects it
# as the X-Envoy-Internal-JWT request header.  The app validates it with the
# public key.  No external JWT library is required on either side.
echo ""
echo "▶  Generating JWT RS256 keypair"

openssl genrsa -out "$OUT/jwt.key" 2048 2>/dev/null
openssl rsa    -in  "$OUT/jwt.key" -pubout -out "$OUT/jwt.pub" 2>/dev/null
echo "   RSA keypair: jwt.key / jwt.pub"

echo "▶  Minting RS256 JWT token"

# base64url-encode stdin (no padding, no line-wraps)
b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

HDR=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
# Expiry: now + 100 years (effectively permanent for this test environment)
EXP=$(( $(date +%s) + 3153600000 ))
PAY=$(printf '%s' "{\"iss\":\"envoy-sidecar\",\"sub\":\"envoy-internal\",\"exp\":${EXP}}" | b64url)
SIG=$(printf '%s' "${HDR}.${PAY}" | openssl dgst -sha256 -sign "$OUT/jwt.key" -binary | b64url)
TOKEN="${HDR}.${PAY}.${SIG}"
printf '%s' "$TOKEN" > "$OUT/jwt.token"
echo "   JWT token written to $OUT/jwt.token  (exp epoch: ${EXP})"

# ── envoy-jwt-token secret ─────────────────────────────────────────────────
# Mounted read-only into the Envoy sidecar at /jwt.
# The Lua filter reads /jwt/jwt.token and injects it as a Bearer header.
kubectl create secret generic envoy-jwt-token \
  --namespace="$NS" \
  --from-file=jwt.token="$OUT/jwt.token" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── app-jwt-pubkey secret ─────────────────────────────────────────────────
# Mounted read-only into the app container at /jwt-pubkey.
# The app validates JWT signatures with /jwt-pubkey/jwt.pub.
kubectl create secret generic app-jwt-pubkey \
  --namespace="$NS" \
  --from-file=jwt.pub="$OUT/jwt.pub" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✅  Done. Secrets in namespace '$NS':"
kubectl get secrets -n "$NS" --no-headers | grep -E "f5-sim-certs|haproxy-certs|envoy-certs|client-certs|mock-certs|envoy-jwt-token|app-jwt-pubkey"

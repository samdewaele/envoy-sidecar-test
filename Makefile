###############################################################################
# Makefile — envoy-sidecar-test
#
# Prerequisites: kind, kubectl, helm, helmfile, docker, openssl
#
# Full stack flow:
#   Client ──mTLS──▶ f5-sim ──HTTP+CN-header──▶ haproxy ──TLS──▶ Pod A Envoy ──▶ App
#                                                                Pod A Envoy ──TLS──▶ Pod B Envoy ──▶ App
#
# Quick start:
#   make cluster          create kind cluster + install Calico CNI
#   make build            build testapp image
#   make certs            generate self-signed certs + load as k8s secrets
#   make dev              deploy in DEV mode  (no TLS, no enforcement)
#   make qa               deploy in QA mode   (mTLS on, violations logged)
#   make prod             deploy in PROD mode (violations blocked)
#   make test-dev         smoke test DEV
#   make test-qa          smoke test QA  + show violation logs
#   make test-prod        smoke test PROD + verify blocking
#   make down             destroy the kind cluster
###############################################################################

CLUSTER        := envoy-sidecar-test
NS_CLIENT      := client
NS_APPS        := apps
IMAGE_NAME     := testapp
IMAGE_TAG      := latest
REGISTRY       := localhost:5001
TESTAPP_IMAGE  := $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
export TESTAPP_IMAGE

CALICO_VERSION := v3.27.3
CALICO_URL     := https://raw.githubusercontent.com/projectcalico/calico/$(CALICO_VERSION)/manifests/calico.yaml

.PHONY: help cluster calico registry build push certs plugins \
        dev qa prod \
        egress-matrix test-dev test-qa test-prod \
        logs-f5 logs-haproxy logs-a logs-b logs-gw \
        status down clean

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  Infrastructure"
	@echo "    make cluster      create kind cluster (Calico CNI, NodePort on :30443)"
	@echo "    make registry     start local image registry on port 5001"
	@echo "    make plugins      install helm-diff plugin (auto-run by dev/qa/prod)"
	@echo "    make down         destroy cluster + registry"
	@echo ""
	@echo "  Image"
	@echo "    make build        build testapp Docker image"
	@echo "    make push         build + load image into Kind nodes (no registry needed)"
	@echo ""
	@echo "  Certs"
	@echo "    make certs        generate self-signed certs + load as k8s secrets"
	@echo ""
	@echo "  Deploy (via helmfile)"
	@echo "    make dev          deploy in DEV  mode"
	@echo "    make qa           deploy in QA   mode"
	@echo "    make prod         deploy in PROD mode"
	@echo ""
	@echo "  Test"
	@echo "    make test-dev     smoke test DEV  (all paths should pass)"
	@echo "    make test-qa      smoke test QA   (violations logged, not blocked)"
	@echo "    make test-prod    smoke test PROD (blocked path must fail)"
	@echo ""
	@echo "  Logs"
	@echo "    make logs-f5      tail f5-sim (nginx) logs"
	@echo "    make logs-haproxy tail HAProxy logs"
	@echo "    make logs-a       tail Pod A Envoy logs"
	@echo "    make logs-b       tail Pod B Envoy logs"
	@echo ""

# ── Helm plugins ─────────────────────────────────────────────────────────────
# helmfile apply uses `helm diff` internally — this plugin is not bundled
# with helm and must be installed once.  This target is a no-op if it is
# already present, so it is safe to declare as a dependency of dev/qa/prod.

plugins:
	@helm plugin list 2>/dev/null | grep -q "^diff" \
	  && echo "helm-diff already installed" \
	  || helm plugin install https://github.com/databus23/helm-diff --version 3.9.9

# ── Infrastructure ────────────────────────────────────────────────────────────

cluster:
	@echo "▶  Creating kind cluster..."
	kind create cluster --config kind-config.yaml
	@echo "▶  Installing Calico CNI (required for NetworkPolicy)..."
	kubectl apply -f $(CALICO_URL)
	@echo "▶  Waiting for Calico to be ready..."
	kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s
	@echo "✅  Cluster ready"

registry:
	@if ! docker ps --format '{{.Names}}' | grep -q '^kind-registry$$'; then \
	  docker run -d --restart=always -p 5001:5000 --name kind-registry registry:2; \
	  docker network connect kind kind-registry 2>/dev/null || true; \
	  echo "✅  Registry running at localhost:5001"; \
	else \
	  echo "Registry already running"; \
	fi

# ── Image ─────────────────────────────────────────────────────────────────────

build:
	docker build -t $(TESTAPP_IMAGE) ./testapp

push: build
	@echo "▶  Loading image into Kind nodes..."
	kind load docker-image $(TESTAPP_IMAGE) --name $(CLUSTER)
	@echo "✅  Image ready in cluster"

# ── Certificates ─────────────────────────────────────────────────────────────

certs:
	chmod +x scripts/generate-certs.sh
	./scripts/generate-certs.sh

# ── Deploy ───────────────────────────────────────────────────────────────────
# helmfile merges base values + environment values automatically.
# Image is injected via TESTAPP_IMAGE env var (set at top of this file).

dev: push certs plugins
	helmfile -e dev apply
	@echo ""
	@echo "✅  DEV stack deployed"
	@echo "    Traffic: test-client → f5-sim (no TLS) → haproxy → pod-a envoy (no TLS) → app"

qa: push certs plugins
	helmfile -e qa apply
	@echo ""
	@echo "✅  QA stack deployed"
	@echo "    Traffic: test-client ──mTLS──▶ f5-sim ──HTTP+CN──▶ haproxy ──TLS──▶ pod-a envoy ──▶ app"
	@echo "    Violations: logged with shadow_result=DENY — run 'make logs-a' to watch"

prod: push certs plugins
	helmfile -e prod apply
	@echo ""
	@echo "✅  PROD stack deployed"
	@echo "    Violations: BLOCKED — /call-blocked will return connection reset"

# ── Tests ────────────────────────────────────────────────────────────────────
# Pod A is exercised through the real ingress chain (client → f5 → haproxy →
# pod-a). Pod B's egress is exercised by exec'ing into its app container and
# hitting the sidecar's local egress ports (the client cannot reach pod-b).
#
# The egress gateway enforces authz in EVERY mode (it is a separate control
# plane from the sidecar's inbound RBAC), so the egress matrix is mode-agnostic.
# Only the inbound behaviour differs by mode (prod additionally rejects a
# missing client cert).

F5 := https://f5-sim.f5.svc.cluster.local

_curl_mtls = kubectl exec -n $(NS_CLIENT) client -- curl -sf --max-time 8 \
               --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt

# exec into the pod-b app container (to reach its sidecar's local egress ports)
_execb = kubectl exec -n $(NS_APPS) -c app \
           $$(kubectl get pod -n $(NS_APPS) -l app=pod-b -o jsonpath='{.items[0].metadata.name}') --

# Shared egress authorization matrix — identical in dev/qa/prod.
egress-matrix:
	@echo "── warming up ingress chain + gateway (cold-start guard) ───────"
	@ok=0; for i in $$(seq 1 15); do \
	  if $(_curl_mtls) $(F5)/call-kafka >/dev/null 2>&1; then ok=1; break; fi; \
	  echo "  waiting for chain... ($$i)"; sleep 2; \
	done; \
	if [ $$ok -ne 1 ]; then echo "  ❌ chain never became ready"; exit 1; fi; \
	echo "  ✅ chain ready"
	@echo "── Pod A egress (client → f5 → pod-a) ──────────────────────────"
	$(_curl_mtls) $(F5)/call-b     && echo "  ✅ pod-a → pod-b (direct)"
	$(_curl_mtls) $(F5)/call-kafka && echo "  ✅ pod-a → kafka (gateway)"
	$(_curl_mtls) $(F5)/call-llm   && echo "  ✅ pod-a → llm-gateway (gateway)"
	@echo "→ pod-a → internal-api must be DENIED (gateway: CN not authorized)"
	@if $(_curl_mtls) $(F5)/call-internal >/dev/null 2>&1; then echo "  ❌ UNEXPECTED: allowed"; exit 1; else echo "  ✅ denied by CN"; fi
	@echo "→ pod-a → blocked must be DENIED (gateway: no route)"
	@if $(_curl_mtls) $(F5)/call-blocked >/dev/null 2>&1; then echo "  ❌ UNEXPECTED: allowed"; exit 1; else echo "  ✅ denied (no route)"; fi
	@echo "── Pod B egress (exec → sidecar local egress ports) ────────────"
	@if $(_execb) curl -sf --max-time 8 http://localhost:19094/echo >/dev/null 2>&1; then echo "  ✅ pod-b → internal-api (gateway)"; else echo "  ❌ pod-b → internal-api should be allowed"; exit 1; fi
	@echo "→ pod-b → llm-gateway must be DENIED (gateway: CN not authorized)"
	@if $(_execb) curl -sf --max-time 8 http://localhost:14443/echo >/dev/null 2>&1; then echo "  ❌ UNEXPECTED: allowed"; exit 1; else echo "  ✅ denied by CN"; fi
	@echo "→ pod-b → blocked must be DENIED (gateway: no route)"
	@if $(_execb) curl -sf --max-time 8 http://localhost:19999/echo >/dev/null 2>&1; then echo "  ❌ UNEXPECTED: allowed"; exit 1; else echo "  ✅ denied (no route)"; fi

test-dev: egress-matrix
	@echo "\n════ DEV smoke test ════"
	$(_curl_mtls) $(F5)/health && echo "  ✅ health via f5 (inbound RBAC not loaded)"
	@echo "\n✅  DEV passed"

test-qa: egress-matrix
	@echo "\n════ QA smoke test ════"
	$(_curl_mtls) $(F5)/health && echo "  ✅ health via f5 (inbound RBAC shadow-only)"
	@echo "→ inbound access log (shadow_result on pod-a):"
	kubectl logs -n $(NS_APPS) -l app=pod-a -c envoy --tail=10 || true
	@echo "\n✅  QA passed"

test-prod: egress-matrix
	@echo "\n════ PROD smoke test ════"
	$(_curl_mtls) $(F5)/health && echo "  ✅ health via f5 (inbound RBAC enforced, CN=test-client)"
	@echo "→ Rejection without client cert (must fail the mTLS handshake)"
	@if kubectl exec -n $(NS_CLIENT) client -- \
	     curl -sf --max-time 8 --cacert /certs/ca.crt $(F5)/health >/dev/null 2>&1; then \
	  echo "  ❌ UNEXPECTED: accepted without client cert"; exit 1; \
	else echo "  ✅ rejected without client cert"; fi
	@echo "\n✅  PROD passed"

# ── Logs ─────────────────────────────────────────────────────────────────────

logs-f5:
	kubectl logs -n f5 -l app=f5-sim -f

logs-haproxy:
	kubectl logs -n haproxy -l app=haproxy -f

logs-a:
	kubectl logs -n $(NS_APPS) -l app=pod-a -c envoy -f

logs-b:
	kubectl logs -n $(NS_APPS) -l app=pod-b -c envoy -f

logs-gw:
	kubectl logs -n gateway -l app=gateway -f

# ── Status ───────────────────────────────────────────────────────────────────

status:
	@echo "\n── Pods (all namespaces) ──"
	kubectl get pods -A -o wide | grep -E 'NAME|f5|haproxy|apps|gateway|client|kafka|internal-api|llm-gateway|blocked' || true
	@echo "\n── NetworkPolicies ──"
	kubectl get networkpolicy -A

# ── Teardown ─────────────────────────────────────────────────────────────────

down:
	kind delete cluster --name $(CLUSTER)
	docker rm -f kind-registry 2>/dev/null || true
	@echo "✅  Cluster and registry removed"

clean: down
	rm -rf certs/

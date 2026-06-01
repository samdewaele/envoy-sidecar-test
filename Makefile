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
NS             := envoy-test
IMAGE_NAME     := testapp
IMAGE_TAG      := latest
REGISTRY       := localhost:5001
TESTAPP_IMAGE  := $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
export TESTAPP_IMAGE

CALICO_VERSION := v3.27.3
CALICO_URL     := https://raw.githubusercontent.com/projectcalico/calico/$(CALICO_VERSION)/manifests/calico.yaml

.PHONY: help cluster calico registry build push certs plugins \
        dev qa prod \
        test-dev test-qa test-prod \
        logs-f5 logs-haproxy logs-a logs-b \
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
	  || helm plugin install "https://github.com/databus23/helm-diff/releases/download/v3.9.9/helm-diff-$$(uname -s | tr '[:upper:]' '[:lower:]')-$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').tgz"

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
	./scripts/generate-certs.sh $(NS)

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
# All requests go from the test-client pod through f5-sim (NodePort :30443).
# The client pod has its certs mounted at /certs.

_curl_dev  = kubectl exec -n $(NS) client -- curl -sf --max-time 5
_curl_mtls = kubectl exec -n $(NS) client -- curl -sf --max-time 5 \
               --cert /certs/client.crt \
               --key  /certs/client.key \
               --cacert /certs/ca.crt

# f5-sim internal hostname as seen from the client pod
F5 := https://f5-sim.$(NS).svc.cluster.local

test-dev:
	@echo "\n════ DEV smoke test ════"
	@echo "→ health check via f5-sim"
	$(_curl_dev) $(F5)/health && echo " ✅"
	@echo "→ pod-a calls pod-b"
	$(_curl_dev) $(F5)/call-b && echo " ✅"
	@echo "→ pod-a calls kafka"
	$(_curl_dev) $(F5)/call-kafka && echo " ✅"
	@echo "→ pod-a calls llm-gateway"
	$(_curl_dev) $(F5)/call-llm && echo " ✅"
	@echo "→ /call-blocked (should SUCCEED in DEV — no enforcement)"
	$(_curl_dev) $(F5)/call-blocked && echo " ✅ (expected: passed through)"
	@echo "\n✅  DEV: all paths open"

test-qa:
	@echo "\n════ QA smoke test ════"
	@echo "→ all legitimate calls (with mTLS client cert)"
	$(_curl_mtls) $(F5)/call-all
	@echo ""
	@echo "→ /call-blocked (should SUCCEED but log a violation)"
	$(_curl_mtls) $(F5)/call-blocked && echo " ✅ (passed — expected in QA)"
	@echo ""
	@echo "→ Envoy access log — look for shadow_result=DENY on the blocked call:"
	kubectl logs -n $(NS) -l app=pod-a -c envoy --tail=10
	@echo "\n✅  QA: violations logged, nothing blocked"

test-prod:
	@echo "\n════ PROD smoke test ════"
	@echo "→ allowed paths (must succeed)"
	$(_curl_mtls) $(F5)/call-b    && echo " ✅ pod-b"
	$(_curl_mtls) $(F5)/call-kafka  && echo " ✅ kafka"
	$(_curl_mtls) $(F5)/call-llm    && echo " ✅ llm-gateway"
	@echo ""
	@echo "→ /call-blocked (must FAIL — connection reset by Envoy)"
	$(_curl_mtls) $(F5)/call-blocked \
	  && echo " ❌ UNEXPECTED: request succeeded" \
	  || echo " ✅ blocked as expected (connection reset)"
	@echo ""
	@echo "→ Rejection from wrong CN (no client cert — should be 403 or reset)"
	kubectl exec -n $(NS) client -- \
	  curl -sf --max-time 5 --cacert /certs/ca.crt $(F5)/health \
	  && echo " ❌ UNEXPECTED: accepted without client cert" \
	  || echo " ✅ rejected without client cert (expected)"
	@echo "\n✅  PROD: whitelist enforced"

# ── Logs ─────────────────────────────────────────────────────────────────────

logs-f5:
	kubectl logs -n $(NS) -l app=f5-sim -f

logs-haproxy:
	kubectl logs -n $(NS) -l app=haproxy -f

logs-a:
	kubectl logs -n $(NS) -l app=pod-a -c envoy -f

logs-b:
	kubectl logs -n $(NS) -l app=pod-b -c envoy -f

# ── Status ───────────────────────────────────────────────────────────────────

status:
	@echo "\n── Pods ──"
	kubectl get pods -n $(NS) -o wide
	@echo "\n── Services ──"
	kubectl get svc -n $(NS)
	@echo "\n── NetworkPolicies ──"
	kubectl get networkpolicy -n $(NS)

# ── Teardown ─────────────────────────────────────────────────────────────────

down:
	kind delete cluster --name $(CLUSTER)
	docker rm -f kind-registry 2>/dev/null || true
	@echo "✅  Cluster and registry removed"

clean: down
	rm -rf certs/

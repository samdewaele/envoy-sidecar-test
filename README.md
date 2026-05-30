# envoy-sidecar-test

Toy test stack for an Envoy-based mTLS sidecar pattern.  
Validates the full traffic chain — external client through F5/HAProxy simulation into two
Kubernetes pods — before the sidecar is integrated into the production application chart.

---

## Setup

**Everything runs on your local machine — no cloud account, no VM, no remote cluster.**  
`make cluster` creates a Kubernetes cluster inside Docker using [Kind](https://kind.sigs.k8s.io/).  
The registry, cluster, and all pods are Docker containers on your machine. `make down` cleans everything up.

Pick your OS below and follow the steps in order.

---

### Windows

> **Do not use Git Bash or PowerShell.** The Makefile and cert scripts require bash.  
> Everything below is done inside a **WSL2 terminal** (Ubuntu running inside Windows).

#### Step 1 — Install WSL2

Open **PowerShell as Administrator** (right-click the Start menu → "Windows PowerShell (Admin)") and run:

```powershell
wsl --install
```

This installs WSL2 with Ubuntu. **Restart your computer when prompted.**

After rebooting, Ubuntu will launch automatically and ask you to create a username and password. Do that — this is your Linux account inside Windows.

> If you already have WSL but an older version, run `wsl --update` and `wsl --set-default-version 2`.

#### Step 2 — Open a WSL2 terminal

You'll use this terminal for everything from here on.

- Press the **Windows key**, type **Ubuntu**, click it. A black terminal window opens.
- Or: open **Windows Terminal** (install it from the Microsoft Store if you don't have it) and pick **Ubuntu** from the tab dropdown. This is nicer.

You're now inside Linux. Your Windows files are at `/mnt/c/Users/yourname/` but **don't work there** — file I/O across the Windows/Linux boundary is slow and causes subtle issues with `make`. Keep this project on the Linux filesystem.

#### Step 3 — Install Docker Desktop

Download and install **[Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/)**.

During or after install, open Docker Desktop and go to:  
**Settings** (gear icon, top right) **→ Resources → WSL Integration**

- Make sure **"Enable integration with my default WSL distro"** is ticked.
- If you see your Ubuntu distro listed separately, toggle it on too.
- Click **Apply & Restart**.

Go back to your Ubuntu terminal and verify Docker is working:

```bash
docker ps
```

Expected output: an empty table with column headers (no error). If you get `permission denied` or `Cannot connect`, Docker Desktop is not running or the WSL integration wasn't saved — recheck the settings above.

#### Step 4 — Install the project tools

> ⚠️ `sudo apt install kind helm kubectl helmfile` **will not work** — these tools are not in Ubuntu's default package repository. The script below installs them from their official sources.

In your Ubuntu terminal, clone this repo onto the **Linux** filesystem and run the install script:

```bash
# Clone into your Linux home directory (fast — stays on the Linux filesystem)
cd ~
git clone https://github.com/samdewaele/envoy-sidecar-test.git
cd envoy-sidecar-test

# Install all required tools
chmod +x scripts/install-tools-wsl2.sh
./scripts/install-tools-wsl2.sh
```

The script installs: `make`, `openssl`, `kubectl`, `helm`, `kind`, `helmfile`.  
It takes about 2 minutes. Docker is skipped — it's already handled by Docker Desktop.

#### Step 5 — Verify everything is ready

```bash
docker ps           # should show an empty table, no error
kind version        # kind v0.23.x
kubectl version --client --short
helm version --short
helmfile --version
```

All five commands should print a version number without errors. If any fail, re-run the install script or check the error message.

You're ready. Continue to [Quick start](#quick-start) below.

---

### macOS

#### Step 1 — Install Homebrew

If you don't have it yet:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### Step 2 — Install Docker Desktop

Download **[Docker Desktop for Mac](https://docs.docker.com/desktop/install/mac-install/)** and drag it to Applications.  
Start it, wait for the whale icon to appear in the menu bar (that means it's running).

#### Step 3 — Install the project tools

```bash
brew install kind kubectl helm helmfile openssl
```

#### Step 4 — Clone and verify

```bash
git clone https://github.com/samdewaele/envoy-sidecar-test.git
cd envoy-sidecar-test
docker ps && kind version && kubectl version --client --short && helm version --short && helmfile --version
```

All commands should print without errors. Continue to [Quick start](#quick-start).

---

### Linux (native)

```bash
# Basic tools
sudo apt install -y make git curl openssl

# kubectl — needs the Kubernetes apt repo (not in default Ubuntu repos)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubectl

# helm — official install script
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kind — binary (not in apt)
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind

# helmfile — binary (not in apt)
curl -fsSLo /tmp/helmfile.tar.gz \
  https://github.com/helmfile/helmfile/releases/download/v0.162.0/helmfile_0.162.0_linux_amd64.tar.gz
tar -xzf /tmp/helmfile.tar.gz -C /tmp helmfile && sudo mv /tmp/helmfile /usr/local/bin/

# docker engine
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # then log out and back in

# clone
git clone https://github.com/samdewaele/envoy-sidecar-test.git
cd envoy-sidecar-test
```

---

## Quick start

### 1. Create the cluster

```bash
make cluster
```

This creates a Kind cluster with:
- Default CNI disabled
- Calico installed and waited on
- NodePort 30443 mapped to `localhost:30443` (f5-sim entry point from host)

Expected output:
```
▶  Creating kind cluster...
▶  Installing Calico CNI (required for NetworkPolicy)...
▶  Waiting for Calico to be ready...
✅  Cluster ready
```

### 2. Start the local image registry

```bash
make registry
```

Runs a local Docker registry on `localhost:5001` and connects it to the Kind network.
Only needed once per machine.

### 3. Build and push the testapp image

```bash
make build
```

Builds `testapp/main.go` into a minimal Go binary and pushes it to the local registry.
The same image is used for Pod A, Pod B, and all mock targets — role is set by the
`APP_ROLE` env var.

### 4. Generate certificates

```bash
make certs
```

Runs `scripts/generate-certs.sh`, which:

1. Generates a self-signed CA (`certs/ca.crt`)
2. Issues leaf certs for: `test-client`, `f5-sim`, `haproxy`, `pod-a`, `pod-b`, mock targets
3. Generates an RSA-2048 keypair and mints a pre-signed RS256 JWT for Envoy's Lua injector
4. Creates Kubernetes Secrets in the `envoy-test` namespace:

| Secret | Used by | Contains |
|---|---|---|
| `f5-sim-certs` | f5-sim nginx | `tls.crt`, `tls.key`, `ca.crt` |
| `haproxy-certs` | HAProxy | `haproxy.pem` (cert+key), `ca.crt` |
| `envoy-certs` | Pod A + Pod B Envoy sidecars | `tls.crt`, `tls.key`, `ca.crt` |
| `client-certs` | test-client pod | `client.crt`, `client.key`, `ca.crt` |
| `mock-certs` | all mock target pods | `tls.crt`, `tls.key`, `ca.crt` |
| `envoy-jwt-token` | Envoy sidecar (Lua filter) | `jwt.token` — pre-signed RS256 JWT |
| `app-jwt-pubkey` | app container | `jwt.pub` — RSA public key for verification |

> **Note**: `certs/` is in `.gitignore`.  Never commit private keys.

---

## Testing

### Deploy DEV mode

```bash
make dev
```

Deploys the full stack with `envoy.mode: dev`.  
mTLS is active on every hop.  Envoy's RBAC filter is not loaded — all traffic that
presents a valid CA-signed cert is accepted and forwarded.

Run the smoke test:

```bash
make test-dev
```

Expected output — every path succeeds, including `/call-blocked`:

```
════ DEV smoke test ════
→ health check via f5-sim           ✅
→ pod-a calls pod-b                 ✅
→ pod-a calls kafka                 ✅
→ pod-a calls llm-gateway           ✅
→ /call-blocked (no enforcement)    ✅ (expected: passed through)
```

What this confirms:
- mTLS handshake works end-to-end through f5-sim → haproxy → Pod A Envoy
- Pod A can reach Pod B over mTLS
- Pod A can reach Kafka and LLM gateway mocks
- The sidecar does not break anything before RBAC is enabled

### Deploy QA mode

```bash
make qa
```

Deploys with `envoy.mode: qa`.  
mTLS is active.  RBAC rules are evaluated using `shadow_rules` — violations are **logged**
but traffic is **not blocked**.

Run the smoke test:

```bash
make test-qa
```

Expected output — everything still passes, but the log reveals the violation:

```
════ QA smoke test ════
→ all legitimate calls (with mTLS client cert)
  pod-a→pod-b          → HTTP 200 ...
  pod-a→kafka          → TCP OK ...
  pod-a→llm            → HTTP 200 ...
→ /call-blocked — should succeed but log a violation
  pod-a→BLOCKED        → HTTP 200 ...  ✅ (passed — expected in QA)

→ Envoy access log — look for shadow_result=DENY on the blocked call:
[2024-...] "GET /call-blocked ..." 200 - bytes=... cn="test-client" shadow_result=DENY
                                                                     ^^^^^^^^^^^^^^^^^^
```

The `shadow_result=DENY` in the access log is the QA violation alert.  
Watch it live:

```bash
make logs-a
```

You can also hit each pod's outbound test endpoints individually:

```bash
# From inside the client pod:
kubectl exec -n envoy-test client -- curl -sf \
  --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt \
  https://f5-sim.envoy-test.svc.cluster.local/call-all
```

### Deploy PROD mode

```bash
make prod
```

Deploys with `envoy.mode: prod`.  
mTLS is active.  RBAC rules are enforced — violations result in a **connection reset**.

Run the smoke test:

```bash
make test-prod
```

Expected output:

```
════ PROD smoke test ════
→ allowed paths (must succeed)
  ✅ pod-b
  ✅ kafka
  ✅ llm-gateway

→ /call-blocked (must FAIL — connection reset by Envoy)
  ✅ blocked as expected (connection reset)

→ Rejection without client cert (should fail mTLS handshake)
  ✅ rejected without client cert (expected)
```

### Verifying the JWT injection

The Envoy Lua filter pre-injects a signed RS256 JWT on every inbound request.  
The app validates it — any request that bypassed Envoy will get a `401`.

To see the injected JWT header in action, hit the `/echo` endpoint and inspect the output:

```bash
kubectl exec -n envoy-test client -- curl -sf \
  --cert /certs/client.crt --key /certs/client.key --cacert /certs/ca.crt \
  https://f5-sim.envoy-test.svc.cluster.local/echo
```

You should see `X-Envoy-Internal-Jwt:` in the headers list — that is the JWT Envoy injected.

To test rejection, make a direct request to the app (bypassing Envoy):

```bash
# Exec into the Pod A app container
kubectl exec -n envoy-test \
  $(kubectl get pod -n envoy-test -l app=pod-a -o jsonpath='{.items[0].metadata.name}') \
  -c app -- curl -sf http://127.0.0.1:9090/echo
# → 401 missing internal auth header
```

### Verifying the NetworkPolicy

NetworkPolicy enforcement is separate from Envoy.  To verify it is actually blocking
traffic at the network level (not just Envoy):

```bash
# Exec into the Pod A app container (not the Envoy sidecar)
kubectl exec -n envoy-test -it \
  $(kubectl get pod -n envoy-test -l app=pod-a -o jsonpath='{.items[0].metadata.name}') \
  -c app -- sh
```

From inside the app container, try to reach a destination that is **not** in the
NetworkPolicy egress whitelist:

```sh
# Should hang / time out — NetworkPolicy drops the packet
wget -T 5 -O- http://sts-mock:8080/health

# Should also be blocked — not in Pod A's whitelist
wget -T 5 -O- http://internal-api-mock:8080/health
```

Both should time out.  If NetworkPolicy is working correctly, the connection never even
reaches Envoy.

Now try a destination that **is** in the whitelist:

```sh
# Should succeed — llm-gateway-mock is in Pod A's egress
wget -T 5 -O- http://llm-gateway-mock:8080/health
```

### Checking Envoy admin

Each sidecar exposes an admin interface on `localhost:9901` (not exposed outside the pod):

```bash
# Port-forward Pod A's Envoy admin
kubectl port-forward -n envoy-test \
  $(kubectl get pod -n envoy-test -l app=pod-a -o jsonpath='{.items[0].metadata.name}') \
  9901:9901

# In another terminal:
curl http://localhost:9901/clusters           # upstream cluster status
curl http://localhost:9901/listeners          # listener config
curl http://localhost:9901/stats?filter=rbac  # RBAC hit/miss counters
```

The `rbac.allowed` and `rbac.denied` counters (or `shadow_engine_result` in QA) are the
key metrics to watch.

### Log reference

| Log line | Meaning |
|---|---|
| `shadow_result=DENY` | QA: request matched a deny rule — would be blocked in PROD |
| `shadow_result=ALLOW` | QA: request passed the whitelist check |
| `shadow_result=-` | DEV: RBAC filter not loaded |
| `RESPONSE_FLAGS=DC` | Connection was terminated by Envoy (PROD block) |
| `RESPONSE_CODE=403` | RBAC denied at HTTP layer |
| `401 missing internal auth header` | Request reached app without going through Envoy |

---

## Switching environments

```bash
make dev    # → helmfile -e dev apply
make qa     # → helmfile -e qa apply
make prod   # → helmfile -e prod apply
```

Helmfile merges `helm/values.yaml` + the environment-specific overlay.  
The image is injected automatically via `TESTAPP_IMAGE` (set at the top of the Makefile).

To preview what would change before applying:

```bash
helmfile -e qa diff
helmfile -e prod diff
```

---

## Architecture

### Full traffic chain

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Kind cluster  (namespace: envoy-test)                                      │
│                                                                             │
│  ┌──────────────┐                                                           │
│  │ test-client  │  kubectl exec → curl with client cert                    │
│  └──────┬───────┘                                                           │
│         │  mTLS  (CN=test-client, verified by CA)                          │
│         ▼                                                                   │
│  ┌──────────────┐  nginx                                                   │
│  │   f5-sim     │  • terminates client TLS                                 │
│  │              │  • verifies client cert against CA                       │
│  │              │  • sets X-SSL-Client-CN: <cn> header                     │
│  └──────┬───────┘                                                           │
│         │  mTLS  (f5-sim presents its own cert to haproxy)                 │
│         ▼                                                                   │
│  ┌──────────────┐  HAProxy                                                 │
│  │   haproxy    │  • terminates mTLS from f5-sim                           │
│  │              │  • re-encrypts (new TLS) toward Pod A Envoy              │
│  │              │  • preserves X-SSL-Client-CN header                      │
│  └──────┬───────┘                                                           │
│         │  mTLS  (haproxy presents its cert; Pod A Envoy requires it)      │
│         ▼                                                                   │
│  ┌─────────────────────────────────────────────────────┐                   │
│  │  Pod A                                              │                   │
│  │  ┌──────────────────┐      ┌────────────────────┐  │                   │
│  │  │   Envoy sidecar  │─────▶│   testapp          │  │                   │
│  │  │   port 8443      │ HTTP │   port 9090        │  │                   │
│  │  │                  │◀─────│   (localhost only) │  │                   │
│  │  │  • mTLS inbound  │      └────────────────────┘  │                   │
│  │  │  • RBAC CN check │                               │                   │
│  │  │  • JWT inject    │                               │                   │
│  │  │  • outbound      │                               │                   │
│  │  │    listeners     │                               │                   │
│  │  └────────┬─────────┘                               │                   │
│  └───────────┼─────────────────────────────────────────┘                   │
│              │                                                              │
│    ┌─────────┼──────────────────────────────────────────┐                  │
│    │         │  mTLS (Pod A cert → Pod B Envoy)          │                  │
│    │         ▼                                           │                  │
│    │  ┌─────────────────────────────────────────────┐   │                  │
│    │  │  Pod B                                      │   │                  │
│    │  │  ┌──────────────────┐  ┌─────────────────┐  │   │                  │
│    │  │  │  Envoy sidecar   │─▶│   testapp       │  │   │                  │
│    │  │  │  port 8443       │  │   port 9090     │  │   │                  │
│    │  │  │  • mTLS inbound  │  │ (localhost only)│  │   │                  │
│    │  │  │  • only Pod A    │  └─────────────────┘  │   │                  │
│    │  │  │    accepted      │                        │   │                  │
│    │  │  │  • JWT inject    │                        │   │                  │
│    │  │  └──────────────────┘                        │   │                  │
│    │  └─────────────────────────────────────────────┘   │                  │
│    │                                                     │                  │
│    │  outbound targets (mTLS — all mocks serve TLS)      │                  │
│    │  ┌─────────────┐  ┌──────────────┐  ┌──────────┐   │                  │
│    │  │ kafka-mock  │  │  sts-mock    │  │ internal │   │                  │
│    │  │  TCP :9092  │  │  HTTP :8080  │  │ api-mock │   │                  │
│    │  └─────────────┘  └──────────────┘  └──────────┘   │                  │
│    └────────────────────────────────────────────────────┘                  │
│                                                                             │
│  additional outbound targets for Pod A                                     │
│  ┌──────────────────┐   ┌────────────────┐                                 │
│  │  llm-gateway-mock│   │  blocked-mock  │  ← only reachable in DEV/QA    │
│  │  HTTP :8080      │   │  HTTP :8080    │    (PROD: connection reset)     │
│  └──────────────────┘   └────────────────┘                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

### mTLS on every hop — no exceptions

| Hop | Who presents cert | Who verifies |
|---|---|---|
| test-client → f5-sim | test-client (CN=`test-client`) | f5-sim (checks CA) |
| f5-sim → haproxy | f5-sim (CN=`f5-sim`) | haproxy (checks CA) |
| haproxy → Pod A Envoy | haproxy (CN=`haproxy`) | Pod A Envoy (checks CA) |
| Pod A Envoy → Pod B Envoy | Pod A (CN=`pod-a`) | Pod B Envoy (checks CA) |
| Envoy → mock targets | Pod A/B (CN=`pod-a`/`pod-b`) | mock (checks CA) |

All certificates are signed by a single self-signed CA (`certs/ca.crt`).  
In production, replace `scripts/generate-certs.sh` with your Vault PKI engine calls.

### JWT: app-layer protection against Envoy bypass

Even with mTLS and NetworkPolicy in place, the app binds on `127.0.0.1` — which means
any process inside the pod can reach it directly without going through Envoy.

To close this gap, Envoy's Lua filter injects a pre-signed RS256 JWT on every forwarded
request.  The app validates the signature on every call (except `/health`):

```
Envoy Lua filter                           App container
────────────────                           ─────────────
reads /jwt/jwt.token (Secret: envoy-jwt-token)
injects header:                            validates header:
  X-Envoy-Internal-JWT: Bearer <token>  →  loadRSAPublicKey(/jwt-pubkey/jwt.pub)
                                           rsa.VerifyPKCS1v15(...)
                                           check iss == "envoy-sidecar"
                                           check exp not expired
```

Private key → `envoy-jwt-token` Secret → **Envoy only**.  
Public key → `app-jwt-pubkey` Secret → **app only**.  
Neither container has access to the other's secret.

### What "mode" controls

Mode is set per environment and **only** changes Envoy's RBAC enforcement.  
Transport (mTLS) and JWT injection are always on.

| | DEV | QA | PROD |
|---|---|---|---|
| mTLS on every hop | ✅ | ✅ | ✅ |
| JWT injection + validation | ✅ | ✅ | ✅ |
| Certs mounted | ✅ | ✅ | ✅ |
| RBAC CN / CIDR whitelist | not loaded | shadow — **logged**, not enforced | enforced — violations **blocked** |
| `/call-blocked` result | mock responds | mock responds + `shadow_result=DENY` in log | connection reset |

---

## Outbound enforcement: Envoy + NetworkPolicy

### Why Envoy alone is not enough

The Envoy outbound listeners sit on `localhost:<port>`.  
The app is configured to connect to those ports, and Envoy then proxies the traffic onward.

The problem: **nothing stops the app from calling a real destination directly**, bypassing
Envoy entirely.  If the app opens a socket to `some-other-service:443` directly, Envoy
never sees it.

### NetworkPolicy: the hard enforcement layer

Kubernetes NetworkPolicy is evaluated by the kernel CNI (Calico in this setup) **before
any packet leaves the pod's network namespace**.  It does not care which process inside
the pod opened the socket — app or sidecar.

```
App opens socket to unauthorized-host:443
        │
        ▼
  NetworkPolicy egress check
  "Is this destination in Pod A's egress whitelist?"
        │
        ├── NO  →  packet silently dropped at kernel level
        │           app gets ETIMEDOUT or ECONNREFUSED
        │
        └── YES →  packet allowed out
                        │
                        ▼
                  Envoy outbound listener
                  (mTLS + RBAC logging/enforcement)
```

This gives two independent enforcement layers:

| Layer | Enforces | Controlled by |
|---|---|---|
| NetworkPolicy | Which pods/ports are reachable at all | `helm/templates/network-policy/` |
| Envoy RBAC | mTLS identity + CN/CIDR policy on allowed traffic | `helm/templates/envoy/_helpers.tpl` |

### How NetworkPolicy is configured in this chart

NetworkPolicy resources live in `helm/templates/network-policy/`.  
They are rendered when `networkPolicy.enabled: true` (the default).

```yaml
# helm/values.yaml
networkPolicy:
  enabled: true   # set false to skip (e.g. if your CNI does not support it)
```

**Pod A policy** (`network-policy/pod-a.yaml`):

```
Ingress:
  allow  haproxy → Pod A : 8443

Egress:
  allow  Pod A → pod-b       : 8443   (Pod B Envoy inbound)
  allow  Pod A → kafka-mock  : 9092
  allow  Pod A → llm-gateway : 8080
  allow  Pod A → kube-dns    : 53/UDP+TCP   (required for STRICT_DNS in Envoy)
  deny   everything else
```

**Pod B policy** (`network-policy/pod-b.yaml`):

```
Ingress:
  allow  Pod A → Pod B : 8443

Egress:
  allow  Pod B → kafka-mock    : 9092
  allow  Pod B → sts-mock      : 8080
  allow  Pod B → internal-api  : 8080
  allow  Pod B → kube-dns      : 53/UDP+TCP
  deny   everything else
```

The selector `matchLabels: app: pod-a` on the NetworkPolicy means it applies to **all
containers in the pod** (both the app container and the Envoy sidecar).  This is
intentional: the policy is pod-scoped, not process-scoped.

### One remaining gap: app bypassing Envoy to an allowed destination

NetworkPolicy cannot distinguish *which process* in a pod opened a connection.  
If Pod A's app calls `pod-b-service:8443` directly (skipping its own Envoy), NetworkPolicy
allows it — because `pod-b:8443` is in the egress whitelist.

**Pod B's Envoy closes this gap**: `require_client_certificate: true` means Pod B only
accepts connections that present a CA-signed certificate.  The app container does not have
one; the Envoy sidecar does.  Any direct app-to-app call therefore fails the mTLS
handshake at Pod B's Envoy.

```
Pod A app → pod-b-service:8443  (bypassing Pod A's Envoy)
                │
                ▼
          Pod B Envoy: TLS handshake
          "Client certificate required"
                │
          app has no cert → handshake fails → connection refused
```

### CNI requirement

NetworkPolicy requires a CNI plugin that actually enforces the rules.  
Kind's default CNI (`kindnet`) **does not**.  This chart's `make cluster` installs **Calico**
automatically after the cluster is created.

If you already have a cluster with a NetworkPolicy-capable CNI (Calico, Cilium, Weave),
set `networkPolicy.enabled: true` and apply normally.  
If your CNI does not support NetworkPolicy, set `networkPolicy.enabled: false` — resources
will be skipped, Envoy still works, but the hard enforcement layer is absent.

---

## Repo layout

```
envoy-sidecar-test/
├── testapp/
│   ├── main.go          single Go binary; role set by APP_ROLE env var
│   │                    roles: pod-a | pod-b | mock
│   └── Dockerfile
│
├── helm/
│   ├── Chart.yaml
│   ├── values.yaml          base values (all environments)
│   ├── values-dev.yaml      DEV overrides  (mode: dev)
│   ├── values-qa.yaml       QA overrides   (mode: qa)
│   ├── values-prod.yaml     PROD overrides (mode: prod)
│   └── templates/
│       ├── namespace.yaml
│       ├── envoy/
│       │   ├── _helpers.tpl          all Envoy config logic (named templates)
│       │   └── configmap-envoy.yaml  renders pod-a + pod-b ConfigMaps
│       ├── f5-sim/           nginx simulating F5 BIG-IP
│       ├── haproxy/          HAProxy re-encrypt tier
│       ├── pod-a/            Pod A deployment + service
│       ├── pod-b/            Pod B deployment + service
│       ├── mocks/            kafka, llm-gateway, sts, internal-api, blocked mocks
│       ├── client/           test-client pod (curl + certs)
│       └── network-policy/   Pod A + Pod B NetworkPolicy resources
│
├── helmfile.yaml        environment-aware deployment (dev / qa / prod)
├── kind-config.yaml     Kind cluster config (Calico CNI, NodePort :30443)
├── scripts/
│   └── generate-certs.sh   self-signed CA + leaf certs + JWT keypair + k8s secrets
├── Makefile
└── .gitignore           excludes certs/
```

---

## Moving to production

When you are satisfied with the toy setup:

1. **Replace cert generation** — swap `scripts/generate-certs.sh` with an init container
   that calls your Vault PKI engine to issue certs at pod startup.

2. **Tighten CIDRs and CNs** — update `values-prod.yaml`:
   ```yaml
   podA:
     inbound:
       allowedSourceCIDRs:
         - "10.x.x.x/27"    # your F5 egress CIDR
       allowedClientCNs:
         - "your-f5-client-cn"
   ```

3. **Add the sidecar to your existing chart** — the `helm/templates/envoy/` directory
   and its values keys are self-contained.  Copy them next to your existing templates,
   then add to your pod specs:
   ```yaml
   # In your existing Deployment template:
   containers:
     {{- include "envoy.sidecarContainer" . | nindent 6 }}
   volumes:
     {{- include "envoy.volumes" . | nindent 6 }}
   ```

4. **Update app upstream config** — point each outbound target to its Envoy localhost
   listener port (e.g. `localhost:19080` for Pod B, `localhost:19092` for Kafka).

5. **Apply NetworkPolicy** with real CIDRs from your cluster's pod CIDR ranges.

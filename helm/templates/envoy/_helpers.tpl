{{/*
=============================================================================
envoy/_helpers.tpl
Composes the Envoy static config for each pod role.

Transport rule (non-negotiable, all modes):
  EVERY listener uses mTLS (require_client_certificate: true).
  EVERY upstream cluster that talks to another Envoy sidecar uses mTLS.
  Mock targets (kafka, llm, sts, internal-api) use plain TCP/HTTP because
  they are toy test responders — in production replace with real TLS clusters.

Mode only controls RBAC enforcement (application-layer policy):
  dev  — no RBAC filter → Envoy passes everything; useful for bring-up
  qa   — shadow_rules   → RBAC evaluated, violations LOGGED, traffic passes
  prod — rules          → RBAC enforced, violations BLOCKED (connection reset)
=============================================================================
*/}}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: admin block
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.admin" -}}
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .Values.envoy.ports.admin }}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: downstream mTLS context — applied to EVERY inbound listener.
Requires the connecting party to present a CA-signed certificate.
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.downstreamTLS" -}}
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
    require_client_certificate: true
    common_tls_context:
      tls_certificates:
        - certificate_chain:
            filename: {{ .Values.envoy.tls.mountPath }}/tls.crt
          private_key:
            filename: {{ .Values.envoy.tls.mountPath }}/tls.key
      validation_context:
        trusted_ca:
          filename: {{ .Values.envoy.tls.mountPath }}/ca.crt
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: upstream mTLS context — applied to clusters that talk to another Envoy.
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.upstreamTLS" -}}
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
    common_tls_context:
      tls_certificates:
        - certificate_chain:
            filename: {{ .Values.envoy.tls.mountPath }}/tls.crt
          private_key:
            filename: {{ .Values.envoy.tls.mountPath }}/tls.key
      validation_context:
        trusted_ca:
          filename: {{ .Values.envoy.tls.mountPath }}/ca.crt
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: access log (stdout, structured)
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.accessLog" -}}
access_log:
  - name: envoy.access_loggers.stdout
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
      log_format:
        text_format_source:
          inline_string: "[%START_TIME%] \"%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%\" %RESPONSE_CODE% %RESPONSE_FLAGS% bytes=%BYTES_SENT% cn=\"%REQ(X-SSL-CLIENT-CN)%\" shadow=%DYNAMIC_METADATA(envoy.filters.http.rbac:shadow_engine_result)%\n"
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: HTTP RBAC filter — mode-driven, never removes mTLS.

  dev  → not emitted (no RBAC filter; Envoy passes everything)
  qa   → shadow_rules only; violations appear in access log as shadow_result=DENY
  prod → enforced; non-matching requests receive 403 / connection reset
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.rbacFilter" -}}
{{- $mode := .Values.envoy.mode -}}
{{- $cns  := .allowedCNs -}}
{{- $cdr  := .allowedCIDRs -}}
{{- $hdr  := .cnHeader -}}
{{- if ne $mode "dev" -}}
- name: envoy.filters.http.rbac
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC
{{- if eq $mode "qa" }}
    # QA: shadow_rules only — policy is evaluated and logged but never enforced.
    # rules: is intentionally absent; an empty rules: {} would deny all traffic.
    # Look for shadow_result=DENY in the access log to spot violations.
    shadow_rules_stat_prefix: "whitelist_shadow."
    shadow_rules:
{{- else }}
    # PROD: enforced — requests not matching any policy are denied.
    rules:
{{- end }}
      action: ALLOW
      policies:
        allowed-cn:
          permissions:
            - any: true
          principals:
            - or_ids:
                ids:
{{- range $cns }}
                  - header:
                      name: {{ $hdr | quote }}
                      string_match:
                        exact: {{ . | quote }}
{{- end }}
        allowed-source-cidr:
          permissions:
            - any: true
          principals:
            - or_ids:
                ids:
{{- range $cdr }}
                  - direct_remote_ip:
                      address_prefix: {{ regexFind "^[^/]+" . | quote }}
                      prefix_len: {{ regexFind "[0-9]+$" . | int }}
{{- end }}
{{- end }}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: JWT injector Lua filter — inserted into every INBOUND HCM filter chain.

Reads a pre-signed RS256 JWT from the file mounted from envoy-jwt-token secret
and injects it as a request header (default: X-Envoy-Internal-JWT).
The app container validates the JWT with the public key from app-jwt-pubkey
secret.  The private key is NEVER mounted into the app container.

When jwt.enabled is false the template emits nothing and the app skips
validation (JWT_PUBKEY_FILE env var will not be set).
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.jwtInjectorFilter" -}}
{{- if .Values.envoy.jwt.enabled -}}
- name: envoy.filters.http.lua
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
    default_source_code:
      inline_string: |
        -- Token is loaded lazily once per worker thread and then cached.
        local _jwt_token = nil
        function envoy_on_request(request_handle)
          if _jwt_token == nil then
            local f = io.open("{{ .Values.envoy.jwt.tokenMountPath }}/jwt.token", "r")
            if f then
              _jwt_token = f:read("*l") or ""
              f:close()
            else
              _jwt_token = ""
            end
          end
          if _jwt_token ~= "" then
            request_handle:headers():replace("{{ .Values.envoy.jwt.headerName }}", "Bearer " .. _jwt_token)
          end
        end
{{- end -}}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: health listener — plain HTTP on 0.0.0.0 for kubelet liveness/readiness.

The admin interface stays bound to 127.0.0.1 (it exposes /config_dump,
/quitquitquit and other sensitive endpoints — never expose it on the pod IP).
This listener returns a static 200 via direct_response so kubelet, which
probes from outside the pod's network namespace, has something reachable.
It carries no application traffic and needs no mTLS.
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.healthListener" -}}
- name: health
  address:
    socket_address:
      address: 0.0.0.0
      port_value: {{ .Values.envoy.ports.health }}
  filter_chains:
    - filters:
        - name: envoy.filters.network.http_connection_manager
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            stat_prefix: health
            codec_type: AUTO
            route_config:
              name: health_route
              virtual_hosts:
                - name: health
                  domains: ["*"]
                  routes:
                    - match: { prefix: "/" }
                      direct_response:
                        status: 200
                        body:
                          inline_string: "OK"
            http_filters:
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: outbound TCP-proxy listener (plain TCP, e.g. Kafka mock)
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.outboundTCPListener" -}}
- name: {{ .name }}
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .localPort }}
  filter_chains:
    - filters:
        - name: envoy.filters.network.tcp_proxy
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
            stat_prefix: {{ .name }}
            cluster: {{ .cluster }}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: outbound HTTP listener (plain HTTP toward mock targets)
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.outboundHTTPListener" -}}
- name: {{ .name }}
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .localPort }}
  filter_chains:
    - filters:
        - name: envoy.filters.network.http_connection_manager
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            stat_prefix: {{ .name }}
            codec_type: AUTO
            route_config:
              name: {{ .name }}_route
              virtual_hosts:
                - name: {{ .name }}
                  domains: ["*"]
                  routes:
                    - match: { prefix: "/" }
                      route: { cluster: {{ .cluster }} }
            http_filters:
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: outbound mTLS HTTP listener (toward another Envoy sidecar)
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.outboundMTLSHTTPListener" -}}
- name: {{ .name }}
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .localPort }}
  filter_chains:
    - filters:
        - name: envoy.filters.network.http_connection_manager
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            stat_prefix: {{ .name }}
            codec_type: AUTO
            route_config:
              name: {{ .name }}_route
              virtual_hosts:
                - name: {{ .name }}
                  domains: ["*"]
                  routes:
                    - match: { prefix: "/" }
                      route: { cluster: {{ .cluster }} }
            http_filters:
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: "blocked" outbound listener — tests whitelist-violation behaviour.

  dev  → TCP proxy to blocked-mock; app gets a response
  qa   → network RBAC LOG action + forward to blocked-mock; access log shows violation
  prod → network RBAC ALLOW with empty policies = deny all; connection reset
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.blockedListener" -}}
- name: outbound_blocked
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .Values.envoy.ports.outboundBlocked }}
  filter_chains:
    - filters:
{{- if eq .Values.envoy.mode "prod" }}
        - name: envoy.filters.network.rbac
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.rbac.v3.RBAC
            stat_prefix: "blocked_prod."
            rules:
              action: ALLOW
              policies: {}   # empty = nothing matches = deny all → connection reset
{{- else if eq .Values.envoy.mode "qa" }}
        - name: envoy.filters.network.rbac
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.rbac.v3.RBAC
            stat_prefix: "blocked_qa."
            rules:
              action: LOG
              policies:
                log-violation:
                  permissions:
                    - any: true
                  principals:
                    - any: true
        - name: envoy.filters.network.tcp_proxy
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
            stat_prefix: blocked_qa_fwd
            cluster: blocked_mock
{{- else }}
        - name: envoy.filters.network.tcp_proxy
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
            stat_prefix: blocked_dev
            cluster: blocked_mock
{{- end }}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────────────────
SHARED: static cluster
  tls=true  → mTLS (all inter-pod and Envoy→mock traffic)
  tls=false → plain (loopback to local app only; never used for network traffic)
─────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "envoy.cluster" -}}
- name: {{ .name }}
  type: STRICT_DNS
  connect_timeout: 5s
  load_assignment:
    cluster_name: {{ .name }}
    endpoints:
      - lb_endpoints:
          - endpoint:
              address:
                socket_address:
                  address: {{ .address }}
                  port_value: {{ .port }}
{{- if .tls }}
{{- include "envoy.upstreamTLS" (dict "Values" .Values) | nindent 2 }}
{{- end }}
{{- end }}

{{/*
=============================================================================
POD A — full Envoy config
=============================================================================
*/}}
{{- define "envoy.config.podA" -}}
{{ include "envoy.admin" . }}

static_resources:
  listeners:
    # ── Inbound ──────────────────────────────────────────────────────────────
    # HAProxy connects here after its mTLS re-encrypt.
    # mTLS is ALWAYS required — mode only controls RBAC enforcement.
    - name: inbound
      address:
        socket_address:
          address: 0.0.0.0
          port_value: {{ .Values.envoy.ports.inbound }}
      filter_chains:
        - {{ include "envoy.downstreamTLS" . | nindent 10 }}
          filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: inbound_pod_a
                codec_type: AUTO
                use_remote_address: true
                {{- include "envoy.accessLog" . | nindent 16 }}
                route_config:
                  name: inbound_route
                  virtual_hosts:
                    - name: local
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: local_app }
                http_filters:
                  {{- include "envoy.rbacFilter" (dict
                        "Values"       .Values
                        "allowedCNs"   .Values.podA.inbound.allowedClientCNs
                        "allowedCIDRs" .Values.podA.inbound.allowedSourceCIDRs
                        "cnHeader"     .Values.podA.inbound.cnHeader) | nindent 18 }}
                  {{- include "envoy.jwtInjectorFilter" . | nindent 18 }}
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

    # ── Health (plain HTTP on 0.0.0.0 for kubelet probes) ─────────────────────
    {{- include "envoy.healthListener" . | nindent 4 }}

    # ── Outbound: Pod B (mTLS — Pod B has an Envoy sidecar) ──────────────────
    {{- include "envoy.outboundMTLSHTTPListener" (dict
          "name"      "outbound_pod_b"
          "localPort" .Values.envoy.ports.outboundPodB
          "cluster"   "pod_b") | nindent 4 }}

    # ── Outbound: Kafka mock (plain TCP — toy mock, no TLS) ───────────────────
    {{- include "envoy.outboundTCPListener" (dict
          "name"      "outbound_kafka"
          "localPort" .Values.envoy.ports.outboundKafka
          "cluster"   "kafka") | nindent 4 }}

    # ── Outbound: LLM Gateway mock (plain HTTP — toy mock) ───────────────────
    {{- include "envoy.outboundHTTPListener" (dict
          "name"      "outbound_llm"
          "localPort" .Values.envoy.ports.outboundLLM
          "cluster"   "llm_gateway") | nindent 4 }}

    # ── Outbound: Blocked (whitelist-violation test) ──────────────────────────
    {{- include "envoy.blockedListener" . | nindent 4 }}

  clusters:
    - name: local_app
      type: STATIC
      connect_timeout: 5s
      load_assignment:
        cluster_name: local_app
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: {{ .Values.envoy.ports.appPort }}

    # Pod B — mTLS: ALWAYS on (Pod B's Envoy requires client cert)
    {{- include "envoy.cluster" (dict
          "name"    "pod_b"
          "address" .Values.podA.outbound.podB.address
          "port"    .Values.podA.outbound.podB.port
          "tls"     true
          "Values"  .Values) | nindent 4 }}

    # Kafka mock — mTLS TCP
    {{- include "envoy.cluster" (dict
          "name"    "kafka"
          "address" .Values.podA.outbound.kafka.address
          "port"    .Values.podA.outbound.kafka.port
          "tls"     true
          "Values"  .Values) | nindent 4 }}

    # LLM Gateway mock — mTLS
    {{- include "envoy.cluster" (dict
          "name"    "llm_gateway"
          "address" .Values.podA.outbound.llmGateway.address
          "port"    .Values.podA.outbound.llmGateway.port
          "tls"     true
          "Values"  .Values) | nindent 4 }}

    # Blocked mock — mTLS (DEV/QA only; PROD never reaches this cluster)
    {{- include "envoy.cluster" (dict
          "name"    "blocked_mock"
          "address" "blocked-mock"
          "port"    .Values.mocks.blocked.httpPort
          "tls"     true
          "Values"  .Values) | nindent 4 }}
{{- end }}


{{/*
=============================================================================
POD B — full Envoy config
=============================================================================
*/}}
{{- define "envoy.config.podB" -}}
{{ include "envoy.admin" . }}

static_resources:
  listeners:
    # ── Inbound ──────────────────────────────────────────────────────────────
    # Only Pod A's Envoy sidecar should reach this.
    # mTLS is ALWAYS required.
    - name: inbound
      address:
        socket_address:
          address: 0.0.0.0
          port_value: {{ .Values.envoy.ports.inbound }}
      filter_chains:
        - {{ include "envoy.downstreamTLS" . | nindent 10 }}
          filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: inbound_pod_b
                codec_type: AUTO
                use_remote_address: true
                {{- include "envoy.accessLog" . | nindent 16 }}
                route_config:
                  name: inbound_route
                  virtual_hosts:
                    - name: local
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: local_app }
                http_filters:
                  {{- include "envoy.rbacFilter" (dict
                        "Values"       .Values
                        "allowedCNs"   .Values.podB.inbound.allowedClientCNs
                        "allowedCIDRs" .Values.podB.inbound.allowedSourceCIDRs
                        "cnHeader"     .Values.podB.inbound.cnHeader) | nindent 18 }}
                  {{- include "envoy.jwtInjectorFilter" . | nindent 18 }}
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

    # ── Health (plain HTTP on 0.0.0.0 for kubelet probes) ─────────────────────
    {{- include "envoy.healthListener" . | nindent 4 }}

    # ── Outbound: Kafka mock (plain TCP — toy mock) ───────────────────────────
    {{- include "envoy.outboundTCPListener" (dict
          "name"      "outbound_kafka"
          "localPort" .Values.envoy.ports.outboundKafka
          "cluster"   "kafka") | nindent 4 }}

    # ── Outbound: STS mock (plain HTTP — toy mock) ────────────────────────────
    {{- include "envoy.outboundHTTPListener" (dict
          "name"      "outbound_sts"
          "localPort" .Values.envoy.ports.outboundSTS
          "cluster"   "sts") | nindent 4 }}

    # ── Outbound: Internal API mock (plain HTTP — toy mock) ───────────────────
    {{- include "envoy.outboundHTTPListener" (dict
          "name"      "outbound_internal"
          "localPort" .Values.envoy.ports.outboundInternal
          "cluster"   "internal_api") | nindent 4 }}

    # ── Outbound: Blocked ────────────────────────────────────────────────────
    {{- include "envoy.blockedListener" . | nindent 4 }}

  clusters:
    - name: local_app
      type: STATIC
      connect_timeout: 5s
      load_assignment:
        cluster_name: local_app
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: {{ .Values.envoy.ports.appPort }}

    {{- include "envoy.cluster" (dict
          "name"    "kafka"
          "address" .Values.podB.outbound.kafka.address
          "port"    .Values.podB.outbound.kafka.port
          "tls"     true
          "Values"  .Values) | nindent 4 }}

    {{- include "envoy.cluster" (dict
          "name"    "sts"
          "address" .Values.podB.outbound.sts.address
          "port"    .Values.podB.outbound.sts.port
          "tls"     true
          "Values"  .Values) | nindent 4 }}

    {{- include "envoy.cluster" (dict
          "name"    "internal_api"
          "address" .Values.podB.outbound.internalAPI.address
          "port"    .Values.podB.outbound.internalAPI.port
          "tls"     true
          "Values"  .Values) | nindent 4 }}

    # Blocked mock — mTLS (DEV/QA only; PROD never reaches this cluster)
    {{- include "envoy.cluster" (dict
          "name"    "blocked_mock"
          "address" "blocked-mock"
          "port"    .Values.mocks.blocked.httpPort
          "tls"     true
          "Values"  .Values) | nindent 4 }}
{{- end }}

{{/*
=============================================================================
envoy/_helpers.tpl — Envoy sidecar config for each pod role.

Transport (all modes): EVERY listener and inter-pod cluster uses mTLS.
Inbound RBAC (mode-driven):
  dev  — no RBAC filter (all authenticated callers allowed)
  qa   — shadow_rules: evaluated, violations LOGGED, traffic passes
  prod — enforced: non-matching requests get 403 / reset

Egress: the sidecar no longer authorizes egress. Every external target is a
tcp_proxy to the shared egress GATEWAY over mTLS with a per-target SNI; the
gateway enforces per-CN authorization and routing. Pod B is the only direct
(east-west) hop and stays sidecar-to-sidecar.
=============================================================================
*/}}

{{- define "envoy.admin" -}}
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: {{ .Values.envoy.ports.admin }}
{{- end }}

{{/* downstream mTLS — applied to every inbound listener */}}
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

{{/* upstream mTLS — for the direct Pod B cluster (no SNI override needed) */}}
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

{{- define "envoy.accessLog" -}}
access_log:
  - name: envoy.access_loggers.stdout
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
      log_format:
        text_format_source:
          inline_string: "[%START_TIME%] \"%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%\" %RESPONSE_CODE% %RESPONSE_FLAGS% bytes=%BYTES_SENT% cn=\"%REQ(X-SSL-CLIENT-CN)%\" shadow=%DYNAMIC_METADATA(envoy.filters.http.rbac:shadow_engine_result)%\n"
{{- end }}

{{/* Inbound HTTP RBAC — mode-driven (dev: omitted, qa: shadow, prod: enforced) */}}
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
    shadow_rules_stat_prefix: "whitelist_shadow."
    shadow_rules:
{{- else }}
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

{{/* JWT injector Lua filter — inserted into every inbound HCM chain */}}
{{- define "envoy.jwtInjectorFilter" -}}
{{- if .Values.envoy.jwt.enabled -}}
- name: envoy.filters.http.lua
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
    default_source_code:
      inline_string: |
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

{{/* Health listener — plain HTTP 200 on 0.0.0.0 for kubelet probes */}}
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

{{/* Local outbound tcp-proxy listener (app plaintext → cluster) */}}
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

{{/* Local outbound mTLS HTTP listener (toward another Envoy sidecar — Pod B) */}}
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

{{/* Direct cluster (local_app loopback, or Pod B over mTLS when tls=true) */}}
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
Gateway egress cluster — points at the shared egress gateway, with a
per-target SNI so the gateway can route. mTLS presents the pod's own cert
(CN=pod-a / pod-b), which the gateway uses for authorization.
*/}}
{{- define "envoy.gatewayCluster" -}}
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
                  address: {{ .gatewayAddr }}
                  port_value: {{ .gatewayPort }}
  transport_socket:
    name: envoy.transport_sockets.tls
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
      sni: {{ .sni | quote }}
      common_tls_context:
        tls_certificates:
          - certificate_chain:
              filename: {{ .mountPath }}/tls.crt
            private_key:
              filename: {{ .mountPath }}/tls.key
        validation_context:
          trusted_ca:
            filename: {{ .mountPath }}/ca.crt
{{- end }}

{{/*
Shared egress listeners + clusters toward the gateway (identical for both
pods — the gateway, not the sidecar, decides which CN may use which SNI).
Renders the four gateway-bound listeners and their clusters.
*/}}
{{- define "envoy.gatewayEgressListeners" -}}
{{- include "envoy.outboundTCPListener" (dict "name" "outbound_kafka"    "localPort" .Values.envoy.ports.outboundKafka    "cluster" "gw_kafka") }}
{{ include "envoy.outboundTCPListener" (dict "name" "outbound_llm"      "localPort" .Values.envoy.ports.outboundLLM      "cluster" "gw_llm_gateway") }}
{{ include "envoy.outboundTCPListener" (dict "name" "outbound_internal" "localPort" .Values.envoy.ports.outboundInternal "cluster" "gw_internal_api") }}
{{ include "envoy.outboundTCPListener" (dict "name" "outbound_blocked"  "localPort" .Values.envoy.ports.outboundBlocked  "cluster" "gw_blocked") }}
{{- end }}

{{- define "envoy.gatewayEgressClusters" -}}
{{- $addr := include "gateway.fqdn" . -}}
{{- $port := .Values.gateway.service.port -}}
{{- $mp := .Values.envoy.tls.mountPath -}}
{{- include "envoy.gatewayCluster" (dict "name" "gw_kafka"        "sni" "kafka"        "gatewayAddr" $addr "gatewayPort" $port "mountPath" $mp) }}
{{ include "envoy.gatewayCluster" (dict "name" "gw_llm_gateway"   "sni" "llm-gateway"  "gatewayAddr" $addr "gatewayPort" $port "mountPath" $mp) }}
{{ include "envoy.gatewayCluster" (dict "name" "gw_internal_api"  "sni" "internal-api" "gatewayAddr" $addr "gatewayPort" $port "mountPath" $mp) }}
{{ include "envoy.gatewayCluster" (dict "name" "gw_blocked"       "sni" "blocked"      "gatewayAddr" $addr "gatewayPort" $port "mountPath" $mp) }}
{{- end }}

{{/* local_app cluster (loopback to the app container) */}}
{{- define "envoy.localAppCluster" -}}
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
{{- end }}

{{/* Inbound listener (shared shape; caller passes stat prefix + RBAC params) */}}
{{- define "envoy.inboundListener" -}}
- name: inbound
  address:
    socket_address:
      address: 0.0.0.0
      port_value: {{ .root.Values.envoy.ports.inbound }}
  filter_chains:
    - {{- include "envoy.downstreamTLS" .root | nindent 6 }}
      filters:
        - name: envoy.filters.network.http_connection_manager
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            stat_prefix: {{ .statPrefix }}
            codec_type: AUTO
            use_remote_address: true
            {{- include "envoy.accessLog" .root | nindent 12 }}
            route_config:
              name: inbound_route
              virtual_hosts:
                - name: local
                  domains: ["*"]
                  routes:
                    - match: { prefix: "/" }
                      route: { cluster: local_app }
            http_filters:
              {{- include "envoy.rbacFilter" (dict "Values" .root.Values "allowedCNs" .allowedCNs "allowedCIDRs" .allowedCIDRs "cnHeader" .cnHeader) | nindent 14 }}
              {{- include "envoy.jwtInjectorFilter" .root | nindent 14 }}
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
{{- end }}

{{/*
=============================================================================
POD A — inbound + direct Pod B + gateway egress
=============================================================================
*/}}
{{- define "envoy.config.podA" -}}
{{ include "envoy.admin" . }}

static_resources:
  listeners:
    {{- include "envoy.inboundListener" (dict "root" . "statPrefix" "inbound_pod_a" "allowedCNs" .Values.podA.inbound.allowedClientCNs "allowedCIDRs" .Values.podA.inbound.allowedSourceCIDRs "cnHeader" .Values.podA.inbound.cnHeader) | nindent 4 }}

    {{- include "envoy.healthListener" . | nindent 4 }}

    # Direct east-west to Pod B (not via gateway)
    {{- include "envoy.outboundMTLSHTTPListener" (dict "name" "outbound_pod_b" "localPort" .Values.envoy.ports.outboundPodB "cluster" "pod_b") | nindent 4 }}

    # Egress via gateway (SNI-routed; gateway enforces per-CN authz)
    {{- include "envoy.gatewayEgressListeners" . | nindent 4 }}

  clusters:
    {{- include "envoy.localAppCluster" . | nindent 4 }}

    {{- include "envoy.cluster" (dict "name" "pod_b" "address" (printf "%s.%s.svc.%s" .Values.podA.outbound.podB.address .Values.namespaces.apps .Values.global.clusterDomain) "port" .Values.podA.outbound.podB.port "tls" true "Values" .Values) | nindent 4 }}

    {{- include "envoy.gatewayEgressClusters" . | nindent 4 }}
{{- end }}

{{/*
=============================================================================
POD B — inbound + gateway egress (no direct Pod B; only Pod A reaches Pod B)
=============================================================================
*/}}
{{- define "envoy.config.podB" -}}
{{ include "envoy.admin" . }}

static_resources:
  listeners:
    {{- include "envoy.inboundListener" (dict "root" . "statPrefix" "inbound_pod_b" "allowedCNs" .Values.podB.inbound.allowedClientCNs "allowedCIDRs" .Values.podB.inbound.allowedSourceCIDRs "cnHeader" .Values.podB.inbound.cnHeader) | nindent 4 }}

    {{- include "envoy.healthListener" . | nindent 4 }}

    # Egress via gateway (SNI-routed; gateway enforces per-CN authz)
    {{- include "envoy.gatewayEgressListeners" . | nindent 4 }}

  clusters:
    {{- include "envoy.localAppCluster" . | nindent 4 }}

    {{- include "envoy.gatewayEgressClusters" . | nindent 4 }}
{{- end }}

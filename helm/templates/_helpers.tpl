{{/*
=============================================================================
Chart-wide helpers
=============================================================================
*/}}

{{/*
chart.fqdn — build a cross-namespace service DNS name.
Usage: include "chart.fqdn" (dict "svc" "kafka-mock" "ns" "kafka" "Values" .Values)
*/}}
{{- define "chart.fqdn" -}}
{{- printf "%s.%s.svc.%s" .svc .ns .Values.global.clusterDomain -}}
{{- end }}

{{/*
gateway.fqdn — the egress gateway's service DNS name.
*/}}
{{- define "gateway.fqdn" -}}
{{- printf "%s.%s.svc.%s" .Values.gateway.name .Values.namespaces.gateway .Values.global.clusterDomain -}}
{{- end }}

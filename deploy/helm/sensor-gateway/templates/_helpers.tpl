{{- define "sensor-gateway.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: sensor-gateway
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sensor-gateway
sensor.mts/track: {{ .Values.track | quote }}
{{- end }}

{{- define "sensor-gateway.selectorLabels" -}}
app.kubernetes.io/name: sensor-gateway
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}

{{- define "sensor-gateway.pullPolicy" -}}
{{- $tag := index . 0 | toString -}}
{{- $policy := index . 1 -}}
{{- if eq $tag "latest" -}}
Always
{{- else -}}
{{- $policy | default "IfNotPresent" -}}
{{- end -}}
{{- end }}

{{/*
Stock apps/web/nginx.conf proxies to hostname "api". Two releases in one
namespace cannot both own that name, so the chart rewrites the same locations
to this release's API Service.
*/}}
{{- define "sensor-gateway.nginxConf" -}}
server {
  listen 80;
  server_name _;
  root /usr/share/nginx/html;
  location /api/ {
    proxy_pass http://{{ .Release.Name }}-api:8000;
    proxy_set_header Host {{ `$host` }};
  }
  location = /health { proxy_pass http://{{ .Release.Name }}-api:8000/health; }
  location = /ready { proxy_pass http://{{ .Release.Name }}-api:8000/ready; }
  location = /metrics { proxy_pass http://{{ .Release.Name }}-api:8000/metrics; }
  location / {
    try_files {{ `$uri $uri/ /index.html` }};
  }
}
{{- end }}

{{- define "demo-service.name" -}}
demo-service
{{- end -}}

{{- define "demo-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-service.name" . }}
{{- end -}}

{{- define "demo-service.labels" -}}
{{ include "demo-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: k8s-observability-blueprint
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

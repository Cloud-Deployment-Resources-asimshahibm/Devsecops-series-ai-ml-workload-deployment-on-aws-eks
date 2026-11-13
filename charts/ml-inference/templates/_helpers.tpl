{{- define "ml-inference.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ml-inference.selectorLabels" -}}
app.kubernetes.io/name: ml-inference
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ml-inference.labels" -}}
{{ include "ml-inference.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ml-platform
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

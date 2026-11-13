{{- define "sp.ecr" -}}
{{ .Values.accountId }}.dkr.ecr.{{ .Values.region }}.amazonaws.com
{{- end -}}

{{- define "sp.mlMatch" -}}
match:
  any:
    - resources:
        kinds: [Pod]
        namespaces:
          {{- toYaml .Values.mlNamespaces | nindent 10 }}
{{- end -}}

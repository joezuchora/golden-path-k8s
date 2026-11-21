{{- define "tenancy.labels" -}}
platform.example.org/team: {{ .Values.team }}
platform.example.org/owner: {{ .Values.owner }}
platform.example.org/cost-center: {{ .Values.costCenter }}
platform.example.org/data-classification: {{ .Values.dataClassification }}
platform.example.org/contract-version: {{ .Values.contractVersion | quote }}
{{- end }}
{{- define "tenancy.validate" -}}
{{- range $k := list "team" "owner" "costCenter" "dataClassification" "deployRepo" }}
{{- if not (index $.Values $k) }}{{ fail (printf "team definition is missing %s" $k) }}{{ end }}
{{- end }}
{{- if not (regexMatch "^[a-z][a-z0-9-]{1,30}$" .Values.team) }}{{ fail "team must be a DNS label" }}{{ end }}
{{- if not (has .Values.capability (list "control-plane" "workloads")) }}{{ fail "capability must be control-plane or workloads" }}{{ end }}
{{- end }}

{{- define "tenancy.labels" -}}
platform.example.org/team: {{ .Values.team }}
platform.example.org/owner: {{ .Values.owner }}
platform.example.org/cost-center: {{ .Values.costCenter }}
platform.example.org/data-classification: {{ .Values.dataClassification }}
platform.example.org/contract-version: {{ .Values.contractVersion | quote }}
{{- end }}
{{- /* The workload group an env's apps are assigned to (D-079): teams/<team>.yaml workloadGroups.<env>, default "shared". */}}
{{- define "tenancy.group" -}}
{{- get (default (dict) .root.Values.workloadGroups) .env | default "shared" -}}
{{- end }}
{{- /* The team's deploy repo (owner/name) on the profile's Git host (D-080): the cluster Secret's deploy-repo template with
{team} substituted (AKS: one GitHub repo per team), else the team file's deployRepo (kind: <team>/deploy on Gitea). */}}
{{- define "tenancy.deployRepo" -}}
{{- with .Values.global.platform.deployRepoTemplate }}{{ replace "{team}" $.Values.team . }}{{ else }}{{ .Values.deployRepo }}{{ end -}}
{{- end }}
{{- define "tenancy.validate" -}}
{{- range $k := list "team" "owner" "costCenter" "dataClassification" "deployRepo" }}
{{- if not (index $.Values $k) }}{{ fail (printf "team definition is missing %s" $k) }}{{ end }}
{{- end }}
{{- if not (regexMatch "^[a-z][a-z0-9-]{1,30}$" .Values.team) }}{{ fail "team must be a DNS label" }}{{ end }}
{{- if not (has .Values.capability (list "control-plane" "workloads")) }}{{ fail "capability must be control-plane or workloads" }}{{ end }}
{{- range $env, $g := (default (dict) .Values.workloadGroups) }}
{{- if not (has $env $.Values.envs) }}{{ fail (printf "workloadGroups names env %q, which isn't in envs %v" $env $.Values.envs) }}{{ end }}
{{- if not (regexMatch "^[a-z][a-z0-9-]{0,30}$" (toString $g)) }}{{ fail (printf "workloadGroups.%s must be a DNS label (got %q)" $env (toString $g)) }}{{ end }}
{{- end }}
{{- with .Values.global.platform.deployRepoTemplate }}
{{- if not (contains "{team}" .) }}{{ fail (printf "deployRepoTemplate %q must contain {team}" .) }}{{ end }}
{{- end }}
{{- end }}

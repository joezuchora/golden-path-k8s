{{- define "gs.labels" -}}
app.kubernetes.io/name: {{ .Values.app }}
app.kubernetes.io/managed-by: golden-service
platform.example.org/app: {{ .Values.app }}
platform.example.org/env: {{ .Values.env }}
platform.example.org/contract-version: {{ .Values.platform.contractVersion | quote }}
{{- end }}

{{- define "gs.host" -}}
{{- if .Values.route.host }}{{ .Values.route.host }}{{- else -}}
{{- if not .Values.platform.domain }}{{ fail "platform.domain is unset: the profile's values-<profile>.yaml must set it, or set route.host" }}{{ end -}}
{{ .Values.app }}-{{ .Release.Namespace }}.{{ .Values.platform.domain }}
{{- end }}
{{- end }}

{{- define "gs.validate" -}}
{{- if not .Values.app }}{{ fail "app is required" }}{{ end }}
{{- if not .Values.env }}{{ fail "env is required" }}{{ end }}
{{- if not .Values.image }}{{ fail "image is required" }}{{ end }}
{{- if not (hasSuffix (printf "-%s" .Values.env) .Release.Namespace) }}{{ fail (printf "env %q doesn't match namespace %q (<team>-<env>)" .Values.env .Release.Namespace) }}{{ end }}
{{- if and .Values.canary.enabled (not .Values.canary.image) }}{{ fail "canary.enabled needs canary.image" }}{{ end }}
{{- end }}

{{- define "gs.headerFilter" -}}
{{- $h := .h }}
{{- if or $h.set $h.add $h.remove }}
- type: {{ .type }}
  {{ .key }}:
    {{- with $h.set }}
    set:
      {{- range $k, $v := . }}
      - {name: {{ $k | quote }}, value: {{ $v | quote }}}
      {{- end }}
    {{- end }}
    {{- with $h.add }}
    add:
      {{- range $k, $v := . }}
      - {name: {{ $k | quote }}, value: {{ $v | quote }}}
      {{- end }}
    {{- end }}
    {{- with $h.remove }}
    remove: {{ toJson . }}
    {{- end }}
{{- end }}
{{- end }}

{{/* One Deployment; called for the stable track and, when enabled, the canary track. */}}
{{- define "gs.deployment" -}}
{{- $v := .root.Values }}
{{- $name := .name }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "gs.labels" .root | nindent 4 }}
    platform.example.org/track: {{ .track }}
  annotations:
    {{- if $v.dependencies.postgres }}
    # Reloader restarts the app when a brokered credential rotates (ADR-0002 step 4).
    secret.reloader.stakater.com/reload: {{ range $i, $d := $v.dependencies.postgres }}{{ if $i }},{{ end }}{{ $v.app }}-{{ $d }}-db{{ end }}
    {{- end }}
spec:
  replicas: {{ .replicas }}
  progressDeadlineSeconds: {{ $v.progressDeadlineSeconds }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      platform.example.org/app: {{ $v.app }}
      platform.example.org/track: {{ .track }}
  template:
    metadata:
      labels:
        {{- include "gs.labels" .root | nindent 8 }}
        platform.example.org/track: {{ .track }}
    spec:
      serviceAccountName: {{ $v.app }}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: app
          image: {{ .image | quote }}
          {{- with $v.args }}
          args: {{ toJson . }}
          {{- end }}
          ports: [{name: http, containerPort: {{ $v.port }}}]
          env:
            - {name: PORT, value: {{ $v.port | quote }}}
            - {name: APP_NAME, value: {{ $v.app | quote }}}
            - {name: APP_ENV, value: {{ $v.env | quote }}}
            - {name: TRACK, value: {{ .track | quote }}}
            {{- range $k, $val := $v.extraEnv }}
            - {name: {{ $k }}, value: {{ $val | quote }}}
            {{- end }}
            {{- with (first $v.dependencies.postgres) }}
            {{- $s := printf "%s-%s-db" $v.app . }}
            - {name: DB_HOST, valueFrom: {secretKeyRef: {name: {{ $s }}, key: host}}}
            - {name: DB_PORT, valueFrom: {secretKeyRef: {name: {{ $s }}, key: port}}}
            - {name: DB_USERNAME, valueFrom: {secretKeyRef: {name: {{ $s }}, key: username}}}
            - {name: DB_PASSWORD, valueFrom: {secretKeyRef: {name: {{ $s }}, key: password, optional: true}}}   # absent with Entra auth (ADR-0008)
            - {name: DB_NAME, valueFrom: {secretKeyRef: {name: {{ $s }}, key: dbname}}}
            {{- end }}
          resources: {{ toJson $v.resources }}
          readinessProbe:
            httpGet: {path: {{ $v.probes.readinessPath }}, port: http}
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: {path: {{ $v.probes.livenessPath }}, port: http}
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
{{- end }}

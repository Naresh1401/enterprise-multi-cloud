{{- define "app.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/version: {{ include "app.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.version" -}}
{{- .Values.image.tag | default .Chart.AppVersion | trunc 63 -}}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "app.fullname" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "app.migrationName" -}}
{{- printf "%s-migrate" (include "app.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Different from the service's, so its Service, NetworkPolicy and budget never select the job */}}
{{- define "app.migrationSelectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}-migrate
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* The sign-in method, checked; call with (list $ auth what) */}}
{{- define "app.databaseAuth" -}}
{{- $auth := index . 1 -}}
{{- if not (has $auth (list "aws-iam" "gcp-iam" "azure-entra" "password")) -}}
{{- fail (printf "%s must be aws-iam, gcp-iam, azure-entra or password, not %q" (index . 2) $auth) -}}
{{- end -}}
{{- $auth -}}
{{- end -}}

{{/* DB_* settings shared by the service and the migration job; call with (list $ auth user) */}}
{{- define "app.databaseEnv" -}}
{{- $root := index . 0 -}}
{{- $db := $root.Values.database -}}
- name: DB_AUTH
  value: {{ index . 1 | quote }}
{{- if $db.host }}
- name: DB_HOST
  value: {{ $db.host | quote }}
- name: DB_PORT
  value: {{ $db.port | quote }}
{{- end }}
{{- if $db.instance }}
- name: DB_INSTANCE
  value: {{ $db.instance | quote }}
{{- end }}
- name: DB_NAME
  value: {{ $db.name | quote }}
- name: DB_USER
  value: {{ index . 2 | quote }}
- name: DB_SSLMODE
  value: {{ $db.sslMode | quote }}
{{- if $db.region }}
- name: AWS_REGION
  value: {{ $db.region | quote }}
{{- end }}
{{- range $name, $value := $db.extraEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end -}}

{{/* NetworkPolicy egress: DNS, the database, then the extra rules; call with (list $ extra) */}}
{{- define "app.egress" -}}
{{- $root := index . 0 -}}
- ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
{{- if $root.Values.database.enabled }}
- ports:
    {{- range $root.Values.database.egress.ports }}
    - port: {{ . }}
      protocol: TCP
    {{- end }}
  {{- with $root.Values.database.egress.to }}
  to:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- with $root.Values.networkPolicy.extraEgress }}
{{ toYaml . }}
{{- end }}
{{- with index . 1 }}
{{ toYaml . }}
{{- end }}
{{- end -}}

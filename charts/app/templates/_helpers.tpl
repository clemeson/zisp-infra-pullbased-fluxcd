{{/* Release name can be overridden when app and release differ. */}}
{{- define "app.name" -}}
{{- .Values.nameOverride | default .Release.Name -}}
{{- end -}}

{{- define "app.labels" -}}
app: {{ include "app.name" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/part-of: {{ .Release.Namespace }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Config and Secret names are stable across upgrades. */}}
{{- define "app.configMapName" -}}
{{- .Values.env.configMap.name | default (printf "%s-config" (include "app.name" .)) -}}
{{- end -}}

{{- define "app.secretName" -}}
{{- .Values.env.secret.name | default (printf "%s-env" (include "app.name" .)) -}}
{{- end -}}

{{- define "app.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- $tag := required "image.tag is required" .Values.image.tag -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}

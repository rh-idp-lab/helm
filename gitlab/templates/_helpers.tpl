{{/*
GitLab User password - Priority: individual user password > global password > random
*/}}
{{- define "gitlab-user.password" -}}
{{- if .user.password }}
{{- .user.password }}
{{- else if .Values.gitlab.users.password }}
{{- .Values.gitlab.users.password }}
{{- else }}
{{- randAlpha 8 }}
{{- end }}
{{- end }}

{{/*
GitLab repository pipeline check
*/}}
{{- define "gitlab.repo.check-pipeline" -}}
{{- $arg := . }}
{{- if $arg.properties }}
{{- if $arg.properties.onlyMergeWhenPipelineSucceeds }}
{{- $arg.properties.onlyMergeWhenPipelineSucceeds }}
{{- else }}
{{- false }}
{{- end }}
{{- else }}
{{- false }}
{{- end }}
{{- end }}

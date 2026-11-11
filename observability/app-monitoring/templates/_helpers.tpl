{{/* Receiver name for a team: "<app>-<team>" */}}
{{- define "app-monitoring.receiver" -}}
{{- printf "%s-%s" .app .team -}}
{{- end -}}

{{/* Validate that defaultTeam is one of the declared teams */}}
{{- define "app-monitoring.validate" -}}
{{- $names := list -}}
{{- range .Values.teams }}{{- $names = append $names .name -}}{{- end -}}
{{- if not (has .Values.defaultTeam $names) -}}
{{- fail (printf "defaultTeam %q is not one of teams %v" .Values.defaultTeam $names) -}}
{{- end -}}
{{- end -}}

#!/usr/bin/env bash
# Generates one self-contained Helm chart folder per bankobs microservice:
#   <svc>/{Chart.yaml, values.yaml, Dockerfile, Makefile,
#          templates/{deployment,service,prometheusrule}.yaml}
#
# Each chart owns its OWN alerting, end to end: templates/prometheusrule.yaml renders a
# per-service PrometheusRule (RED + pod/deploy health, scoped to that one service_name) AND
# templates/alertmanagerconfig.yaml renders a per-service AlertmanagerConfig (WHO is paged for
# this service — its own e-mail recipients). Alerting is MANDATORY: monitoring.enabled defaults
# to TRUE, so every service renders its alerting CRs unless a deploy deliberately opts out. The
# CRDs + Prometheus Operator live on the OBS cluster, so the obs `make app-monitoring` loop
# applies them there; the app release to the BANKOBS cluster (app/Makefile + each svc's own
# `deploy`) is the one explicit opt-out (--set monitoring.enabled=false), because that cluster
# has no PrometheusRule/AlertmanagerConfig CRD. The only central piece left is the SES transport
# (smarthost/auth/From) in the kube-prometheus-stack values.
#
# There is NO service source here. The Dockerfile is a passthrough `FROM` the published
# image, so a student can rebuild, push to THEIR OWN registry and run their own CI/CD —
# the real source stays private. Re-run any time; it is idempotent.
set -euo pipefail
cd "$(dirname "$0")"

REGISTRY_DEFAULT="public.ecr.aws/w8x4g9h7/obs-v1"
TAG_DEFAULT="1.0.0"
OTEL_ENDPOINT="http://otel-collector.obs.internal:4317"   # private, cross-VPC (obs cluster)

# svc|domain|port
SERVICES="
aadhaar-adapter|customer-identity|8032
account-service|core-banking|8001
aml-service|fraud-risk|8042
audit-service|audit-compliance|8060
auth-service|core-banking|8080
balance-service|core-banking|8003
bharat-qr-service|payments|8016
branch-service|core-banking|8007
case-management|fraud-risk|8045
cbs-adapter|core-banking|8008
cersai-adapter|audit-compliance|8063
cheque-service|core-banking|8006
ckyc-service|customer-identity|8034
compliance-checker|audit-compliance|8064
consent-service|customer-identity|8036
credit-card-service|retail-banking|8024
demat-service|retail-banking|8026
eligibility-engine|retail-banking|8028
email-service|notifications|8052
fd-service|retail-banking|8022
fraud-detection|fraud-risk|8040
fx-service|payments|8017
gateway-service|core-banking|8000
ibm-mq-bridge|legacy-stack|8072
identity-vault|customer-identity|8035
imps-service|payments|8014
insurance-service|retail-banking|8025
interest-engine|core-banking|8005
kyc-service|customer-identity|8030
ledger-service|core-banking|8002
loan-origination|retail-banking|8021
loan-service|retail-banking|8020
nach-service|payments|8015
neft-service|payments|8012
notification-orchestrator|notifications|8050
onboarding-service|customer-identity|8031
pan-adapter|customer-identity|8033
payment-gateway|payments|8010
payment-router|payments|8019
pci-logger|audit-compliance|8062
push-service|notifications|8053
rate-limiter|core-banking|8082
rbi-reporter|audit-compliance|8061
rd-service|retail-banking|8023
remittance-service|payments|8018
report-generator|audit-compliance|8065
risk-scoring|fraud-risk|8044
rtgs-service|payments|8013
rules-engine|fraud-risk|8041
sanctions-service|fraud-risk|8043
sms-gateway|notifications|8051
statement-service|core-banking|8004
tomcat-loan-legacy|legacy-stack|8071
transaction-monitor|fraud-risk|8046
upi-service|payments|8011
velocity-checker|fraud-risk|8047
wealth-service|retail-banking|8027
weblogic-cbs-simulator|legacy-stack|8070
whatsapp-service|notifications|8054
"

gen() {
  local svc=$1 domain=$2 port=$3 replicas=$4
  mkdir -p "$svc/templates"

  # RED alerts for a service page the team that owns it. The payments domain is the
  # transaction path (its own on-call); everything else rolls up to platform/SRE. The team
  # name is kept only as a label for grouping/filtering; the actual e-mail recipients are set
  # below and rendered into THIS service's own AlertmanagerConfig.
  local team=platform emails='["platform-sre@example.com"]' critical='[]'
  if [ "$domain" = "payments" ]; then
    team=payments
    emails='["payments-eng@example.com"]'
    critical='["payments-oncall@example.com"]'
  fi

  cat > "$svc/Chart.yaml" <<EOF
apiVersion: v2
name: $svc
description: bankobs microservice $svc ($domain domain)
type: application
version: 1.0.0
appVersion: "$TAG_DEFAULT"
EOF

  cat > "$svc/values.yaml" <<EOF
replicaCount: $replicas
image:
  registry: $REGISTRY_DEFAULT   # override with YOUR ECR (make deploy ECR=...) to run your own build
  tag: "$TAG_DEFAULT"
  pullPolicy: IfNotPresent
service:
  port: $port
domain: $domain
otel:
  endpoint: $OTEL_ENDPOINT
observabilityMode: full
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }

# ── This service's OWN alerting (prometheusrule.yaml + alertmanagerconfig.yaml) ───────────
# enabled defaults to TRUE: alerting is MANDATORY — every service renders its PrometheusRule +
# AlertmanagerConfig. The PrometheusRule / AlertmanagerConfig CRDs + Prometheus Operator live on
# the OBS cluster, so the observability \`make app-monitoring\` loop applies them there. The one
# explicit opt-out is the app release to the BANKOBS cluster (app/Makefile + this chart's own
# \`make deploy\`), which passes --set monitoring.enabled=false because that cluster has no such
# CRD. This service owns BOTH what it alerts on AND who is paged; only the SES transport
# (smarthost/auth/From) is central (kps values).
monitoring:
  enabled: true                # MANDATORY by default; only the bankobs app release opts out
  app: bankobs                 # umbrella label stamped on every alert (grouping / filtering)
  namespace: monitoring        # where Prometheus/Alertmanager watch (obs cluster)
  cluster: obs-v1-bankobs      # k8s_cluster_name stamped on this service's infra metrics
  serviceNamespace: bankobs    # service_namespace (spanmetrics) + k8s_namespace_name (infra)
  team: $team                  # label on RED alerts (grouping / filtering only)
  infraTeam: platform          # label on pod / deployment-health alerts
  errorRateThreshold: 0.05     # HighErrorRate fires above this 5m error ratio
  latencyP95Ms: 1500           # HighLatencyP95 fires above this p95, in ms
  # WHO is paged for this service → rendered into its own AlertmanagerConfig. The SES
  # transport (smarthost/auth/From) is global (kps values); only the recipients live here.
  emails: $emails              # every alert for this service e-mails here
  criticalEmails: $critical    # severity=critical e-mails here instead (pager); [] → use emails
EOF

  cat > "$svc/Dockerfile" <<EOF
# Passthrough image — NO source here. This re-tags the published bankobs image so you
# can push it to YOUR registry and run your own CI/CD, keeping the real source private.
#   make build ECR=<your-ecr>  &&  make push ECR=<your-ecr>
FROM $REGISTRY_DEFAULT/$svc:$TAG_DEFAULT
EOF

  cat > "$svc/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
  labels: { app: {{ .Chart.Name }}, domain: {{ .Values.domain }}, log_format: json }
spec:
  replicas: {{ .Values.replicaCount }}
  selector: { matchLabels: { app: {{ .Chart.Name }} } }
  template:
    metadata:
      labels: { app: {{ .Chart.Name }}, domain: {{ .Values.domain }}, log_format: json }
      # The bankobs-cluster collector agent discovers /metrics via these annotations.
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: "/metrics"
        prometheus.io/port: {{ .Values.service.port | quote }}
    spec:
      # Stop k8s injecting REDIS_PORT=tcp://ip:6379 etc. (service links), which clobbers
      # the apps' ${REDIS_PORT:6379}-style config and breaks Spring/boot startup.
      enableServiceLinks: false
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.registry }}/{{ .Chart.Name }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports: [{ containerPort: {{ .Values.service.port }} }]
          # Shared env: DB creds, auth secrets, and the full-observability telemetry flags.
          envFrom:
            - configMapRef: { name: bankobs-env }
          env:
            - { name: SERVICE_NAME, value: {{ .Chart.Name | quote }} }
            - { name: SERVICE_PORT, value: {{ .Values.service.port | quote }} }
            {{- with .Values.configOverride }}
            # A couple of published images ship a config file that fails to parse and
            # crash-loops the pod. This env var points the JVM at the corrected copy
            # mounted below from the {{ $.Chart.Name }}-config ConfigMap (image-free fix).
            - { name: {{ .env.name }}, value: {{ .env.value | quote }} }
            {{- end }}
          # startupProbe gates liveness/readiness until the app is up. Spring Boot JVMs
          # here boot in 45-60s on throttled/burstable (t3) CPU; without this gate the
          # liveness probe (fires at 30s) kills them right as they finish starting
          # (SIGTERM / exit 143) → CrashLoopBackOff. 30x10s = up to 5 min to come up.
          startupProbe:   { httpGet: { path: /health/live,  port: {{ .Values.service.port }} }, periodSeconds: 10, failureThreshold: 30, timeoutSeconds: 3 }
          livenessProbe:  { httpGet: { path: /health/live,  port: {{ .Values.service.port }} }, periodSeconds: 20, failureThreshold: 3, timeoutSeconds: 3 }
          readinessProbe: { httpGet: { path: /health/ready, port: {{ .Values.service.port }} }, periodSeconds: 10, failureThreshold: 3, timeoutSeconds: 3 }
          {{- with .Values.configOverride }}
          volumeMounts:
            - { name: config-override, mountPath: /config, readOnly: true }
          {{- end }}
          resources:
{{ toYaml .Values.resources | indent 12 }}
      {{- with .Values.configOverride }}
      volumes:
        - name: config-override
          configMap: { name: {{ $.Chart.Name }}-config }
      {{- end }}
EOF

  cat > "$svc/templates/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
  labels: { app: {{ .Chart.Name }}, domain: {{ .Values.domain }} }
spec:
  selector: { app: {{ .Chart.Name }} }
  ports:
    - { name: http, port: {{ .Values.service.port }}, targetPort: {{ .Values.service.port }} }
EOF

  # Per-service alerting CRD. Gated by monitoring.enabled (see values.yaml) so it renders ONLY
  # for the obs-cluster `make app-monitoring` loop, never in the bankobs app release. PromQL `{...}`
  # is single-brace so Helm leaves it alone; Prometheus templating is escaped as {{ "{{ ... }}" }}
  # so a literal {{ ... }} reaches the rendered rule.
  cat > "$svc/templates/prometheusrule.yaml" <<'EOF'
{{- if .Values.monitoring.enabled }}
{{- $m := .Values.monitoring }}
{{- $svc := .Chart.Name }}
# WHAT to alert on for {{ $svc }} — scoped to this one service. RED (error rate + p95 latency)
# from the spanmetrics connector; pod/deployment health from kubeletstats + k8s_cluster. WHO is
# paged for these alerts is this service's OWN AlertmanagerConfig (templates/alertmanagerconfig.yaml).
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ $svc }}-alerts
  namespace: {{ $m.namespace }}
  labels:
    app.kubernetes.io/managed-by: app-monitoring
    app: {{ $m.app }}
    service: {{ $svc }}
spec:
  groups:
    - name: {{ $svc }}.alerts
      rules:
        # ── RED (spanmetrics) → the service's own team ──────────────────────────────────
        - alert: {{ $svc }}HighErrorRate
          expr: >-
            ( sum(rate(calls_total{service_namespace="{{ $m.serviceNamespace }}",service_name="{{ $svc }}",status_code="STATUS_CODE_ERROR"}[5m]))
              / clamp_min(sum(rate(calls_total{service_namespace="{{ $m.serviceNamespace }}",service_name="{{ $svc }}"}[5m])), 1) ) > {{ $m.errorRateThreshold }}
          for: 5m
          labels: { severity: "critical", team: {{ $m.team | quote }}, app: {{ $m.app | quote }}, service: {{ $svc | quote }} }
          annotations:
            summary: "{{ $svc }} error ratio over {{ $m.errorRateThreshold }}"
            description: "5m error ratio for {{ $svc }} is {{ "{{ $value | humanizePercentage }}" }}."
        - alert: {{ $svc }}HighLatencyP95
          expr: >-
            histogram_quantile(0.95, sum by (le) (rate(duration_milliseconds_bucket{service_namespace="{{ $m.serviceNamespace }}",service_name="{{ $svc }}"}[5m]))) > {{ $m.latencyP95Ms }}
          for: 10m
          labels: { severity: "warning", team: {{ $m.team | quote }}, app: {{ $m.app | quote }}, service: {{ $svc | quote }} }
          annotations:
            summary: "{{ $svc }} p95 latency over {{ $m.latencyP95Ms }}ms"
            description: "{{ $svc }} p95 latency is {{ "{{ $value }}" }} ms."
        # ── pod / deployment health (kubeletstats + k8s_cluster) → SRE ──────────────────
        - alert: {{ $svc }}DeploymentDegraded
          expr: >-
            (k8s_deployment_desired{k8s_cluster_name="{{ $m.cluster }}",k8s_namespace_name="{{ $m.serviceNamespace }}",k8s_deployment_name="{{ $svc }}"}
              - k8s_deployment_available{k8s_cluster_name="{{ $m.cluster }}",k8s_namespace_name="{{ $m.serviceNamespace }}",k8s_deployment_name="{{ $svc }}"}) > 0
          for: 10m
          labels: { severity: "warning", team: {{ $m.infraTeam | quote }}, app: {{ $m.app | quote }}, service: {{ $svc | quote }} }
          annotations:
            summary: "{{ $svc }} is short of its desired replicas"
            description: "{{ $svc }} is missing {{ "{{ $value }}" }} replica(s)."
        - alert: {{ $svc }}PodNotRunning
          expr: >-
            count(k8s_pod_phase{k8s_cluster_name="{{ $m.cluster }}",k8s_namespace_name="{{ $m.serviceNamespace }}",k8s_pod_name=~"{{ $svc }}-.*"} == 1
              or k8s_pod_phase{k8s_cluster_name="{{ $m.cluster }}",k8s_namespace_name="{{ $m.serviceNamespace }}",k8s_pod_name=~"{{ $svc }}-.*"} == 4
              or k8s_pod_phase{k8s_cluster_name="{{ $m.cluster }}",k8s_namespace_name="{{ $m.serviceNamespace }}",k8s_pod_name=~"{{ $svc }}-.*"} == 5) > 0
          for: 5m
          labels: { severity: "critical", team: {{ $m.infraTeam | quote }}, app: {{ $m.app | quote }}, service: {{ $svc | quote }} }
          annotations:
            summary: "{{ $svc }} has pod(s) not in Running state"
            description: "{{ "{{ $value }}" }} {{ $svc }} pod(s) are Pending/Failed/Unknown."
        - alert: {{ $svc }}ContainerRestarting
          expr: >-
            increase(k8s_container_restarts{k8s_cluster_name="{{ $m.cluster }}",k8s_namespace_name="{{ $m.serviceNamespace }}",k8s_pod_name=~"{{ $svc }}-.*"}[15m]) > 3
          for: 10m
          labels: { severity: "warning", team: {{ $m.infraTeam | quote }}, app: {{ $m.app | quote }}, service: {{ $svc | quote }} }
          annotations:
            summary: "{{ $svc }} container restarting repeatedly"
            description: "a {{ $svc }} container restarted more than 3 times in 15m."
{{- end }}
EOF

  # Per-service routing CRD — WHO is paged for THIS service. Gated by monitoring.enabled (same
  # reason as the rule: the CRD + operator live on the obs cluster, not here). It carries the
  # selector label alertmanagerConfig=app-monitoring so the Alertmanager CR merges it into the
  # live config. It matches only this service's alerts (service=<svc>); when criticalEmails is
  # set, severity=critical peels off to the pager list (everything else → emails). The SES
  # transport (smarthost/auth/From) is inherited from the global kps Alertmanager config, so
  # only the recipients appear here.
  cat > "$svc/templates/alertmanagerconfig.yaml" <<'EOF'
{{- if .Values.monitoring.enabled }}
{{- $m := .Values.monitoring }}
{{- $svc := .Chart.Name }}
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: {{ $svc }}-routing
  namespace: {{ $m.namespace }}
  labels:
    alertmanagerConfig: app-monitoring
    app.kubernetes.io/managed-by: app-monitoring
    app: {{ $m.app }}
    service: {{ $svc }}
spec:
  route:
    # Every alert for this service lands on its own e-mail receiver by default.
    receiver: {{ $svc }}-email
    groupBy: ["alertname", "app", "service", "severity"]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
      - name: service
        value: {{ $svc | quote }}
        matchType: "="
  {{- if $m.criticalEmails }}
    routes:
      # severity=critical peels off to the pager list and does NOT also hit the default.
      - receiver: {{ $svc }}-critical
        matchers:
          - name: severity
            value: "critical"
            matchType: "="
        continue: false
  {{- end }}
  receivers:
    - name: {{ $svc }}-email
      emailConfigs:
  {{- range $m.emails }}
        - to: {{ . | quote }}
          sendResolved: true
  {{- end }}
  {{- if $m.criticalEmails }}
    - name: {{ $svc }}-critical
      emailConfigs:
    {{- range $m.criticalEmails }}
        - to: {{ . | quote }}
          sendResolved: true
    {{- end }}
  {{- end }}
{{- end }}
EOF

  {
    printf 'SVC := %s\n' "$svc"
    printf 'ECR ?= %s\n' "$REGISTRY_DEFAULT"
    printf 'TAG ?= %s\n' "$TAG_DEFAULT"
    printf 'NS  ?= bankobs\n'
    printf 'CTX ?= obs-v1-bankobs\n\n'
    printf '.PHONY: build push deploy undeploy\n\n'
    printf 'build:\n\tdocker build -t $(ECR)/$(SVC):$(TAG) .\n\n'
    printf 'push:\n\tdocker push $(ECR)/$(SVC):$(TAG)\n\n'
    printf '# monitoring.enabled is ON by default (alerting is mandatory); the bankobs cluster has no\n'
    printf '# PrometheusRule/AlertmanagerConfig CRD, so the deploy here opts out. The alerting CRs are\n'
    printf '# applied to the obs cluster by: make -C ../../observability app-monitoring\n'
    printf 'deploy:\n\thelm --kube-context $(CTX) upgrade --install $(SVC) . -n $(NS) --create-namespace --set image.registry=$(ECR) --set image.tag=$(TAG) --set monitoring.enabled=false\n\n'
    printf 'undeploy:\n\thelm --kube-context $(CTX) uninstall $(SVC) -n $(NS)\n'
  } > "$svc/Makefile"
}

echo "$SERVICES" | while IFS='|' read -r svc domain port; do
  [ -z "$svc" ] && continue
  replicas=1
  gen "$svc" "$domain" "$port" "$replicas"
done
echo "generated $(echo "$SERVICES" | grep -c '|') service charts."

# ─────────────────────────────────────────────────────────────────────────────
#  Image-defect workarounds (2 of the 59 published images ship a config file that
#  fails to parse, so the service crash-loops on startup — nothing in THIS repo is
#  wrong). We can't edit the private image, so each affected chart mounts a CORRECTED
#  copy of the file (a ConfigMap, from config/<file>) and points the JVM at it via an
#  env var. The deployment template above renders the mount/env only when a chart sets
#  `configOverride`, so the other 58 charts are byte-for-byte unchanged.
#
#    • balance-service — BOOT-INF/classes/application.yml wrote the redis block as a YAML
#      *flow* mapping whose values are unquoted ${..} placeholders:
#          redis: { host: ${REDIS_HOST:redis}, port: ${REDIS_PORT:6379} }
#      The '{' inside '${' is illegal in a flow scalar → snakeyaml "expected ',' or '}',
#      but got {". Fixed by writing redis as a block mapping. SPRING_CONFIG_LOCATION makes
#      Spring load ONLY the corrected file (the broken classpath copy is never parsed).
#
#    • cheque-service — BOOT-INF/classes/logback-spring.xml had an XML comment containing
#      '---' ('--' is not permitted inside an XML comment) → logback JoranException at boot.
#      Fixed in the COMMENT only; the runtime <pattern> is untouched, so logging output is
#      byte-identical. LOGGING_CONFIG makes Spring use the corrected logback file.
# ─────────────────────────────────────────────────────────────────────────────
config_override() {   # <svc> <file> <envname> <envval>
  local svc=$1 file=$2 envname=$3 envval=$4
  mkdir -p "$svc/config"
  cat >> "$svc/values.yaml" <<EOF

# Image-defect workaround (see _generate.sh): the published image's $file fails to parse
# and crash-loops the pod; mount a corrected copy at /config and point the JVM at it.
configOverride:
  file: $file
  env: { name: $envname, value: "$envval" }
EOF
  cat > "$svc/templates/config-override.yaml" <<'EOF'
{{- with .Values.configOverride }}
# A corrected copy of a config file that is broken inside the published image. The
# Deployment mounts this at /config and points the JVM at it (see values.yaml).
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $.Chart.Name }}-config
data:
  {{ .file }}: |-
{{ $.Files.Get (printf "config/%s" .file) | indent 4 }}
{{- end }}
EOF
}

config_override balance-service application.yml    SPRING_CONFIG_LOCATION optional:file:/config/application.yml
config_override cheque-service  logback-spring.xml LOGGING_CONFIG         file:/config/logback-spring.xml

# The corrected files. These are the image originals with ONLY the parse bug fixed, so the
# services behave exactly as intended. `${..}` are resolved by Spring at runtime (envFrom
# bankobs-env / SERVICE_* env), so they must stay literal here.
cat > balance-service/config/application.yml <<'EOF'
spring:
  config:
    import: "optional:classpath:application-common.yml"
  application:
    name: balance-service
  datasource:
    url: ${ORACLE_URL:jdbc:oracle:thin:@oracle:1521/XEPDB1}
    username: ${ORACLE_USER:BANKOBS_CORE}
    password: ${ORACLE_PASSWORD:Training123!}
    driver-class-name: oracle.jdbc.OracleDriver
    hikari: { maximum-pool-size: 10, connection-timeout: 5000 }
  data:
    # FIXED: was `redis: { host: ${REDIS_HOST:redis}, port: ${REDIS_PORT:6379} }` — an
    # unquoted ${..} inside a YAML flow mapping is a parse error. Block style avoids it.
    redis:
      host: ${REDIS_HOST:redis}
      port: ${REDIS_PORT:6379}
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:kafka:9092}
    consumer:
      key-deserializer:   org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      auto-offset-reset:  earliest
      group-id:           balance-service
server:
  port: ${SERVICE_PORT:8003}
service:
  version: ${SERVICE_VERSION:1.0.0}
EOF

cat > cheque-service/config/logback-spring.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  ── INTENTIONALLY UNSTRUCTURED LOGGING ──
  cheque-service emits classic Spring Boot console output, NOT JSON.
  This is a Logstash / Fluent Bit parsing lab target — students should
  write a grok pattern that extracts {timestamp, level, thread, logger,
  message} from this format and converts it to JSON in the pipeline.

  Example line (the field after the PID is Spring Boot's three-hyphen
  separator, shown here as [SEP] because an XML comment may not contain
  a literal double hyphen — that is exactly the bug this file fixes):
    2026-06-15 14:23:01.234  INFO 1 [SEP] [           main] c.b.cheque.ChequeController : message
-->
<configuration>
  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} %5p ${PID:- } --- [%15.15t] %-40.40logger{39} : %m%n</pattern>
    </encoder>
  </appender>
  <root level="${LOG_LEVEL:-INFO}">
    <appender-ref ref="CONSOLE"/>
  </root>
</configuration>
EOF
echo "applied config-override workaround to: balance-service, cheque-service."

#!/usr/bin/env bash
# Generates one self-contained Helm chart folder per bankobs microservice:
#   <svc>/{Chart.yaml, values.yaml, Dockerfile, Makefile, templates/{deployment,service}.yaml}
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

  {
    printf 'SVC := %s\n' "$svc"
    printf 'ECR ?= %s\n' "$REGISTRY_DEFAULT"
    printf 'TAG ?= %s\n' "$TAG_DEFAULT"
    printf 'NS  ?= bankobs\n'
    printf 'CTX ?= obs-v1-bankobs\n\n'
    printf '.PHONY: build push deploy undeploy\n\n'
    printf 'build:\n\tdocker build -t $(ECR)/$(SVC):$(TAG) .\n\n'
    printf 'push:\n\tdocker push $(ECR)/$(SVC):$(TAG)\n\n'
    printf 'deploy:\n\thelm --kube-context $(CTX) upgrade --install $(SVC) . -n $(NS) --create-namespace --set image.registry=$(ECR) --set image.tag=$(TAG)\n\n'
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

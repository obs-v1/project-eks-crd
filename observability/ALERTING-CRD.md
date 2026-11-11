# CRD-based alerting (project-eks-crd)

This variant keeps **everything about metric collection the same** as `project-eks` — metrics are
still **OTel-only** (hostmetrics + kubeletstats + k8s_cluster on both clusters, Prometheus as a
remote-write TSDB). The one difference is **how alerting is defined and delivered**: declaratively,
through **Prometheus Operator CRDs**, with e-mail sent via **Amazon SES**.

---

## The model: who owns what

```
   ┌─────────────────────────── per application (app-monitoring chart) ───────────────────────────┐
   │  values-<app>.yaml  ──helm──▶  PrometheusRule   = WHAT to alert on (PromQL over OTel metrics)  │
   │                                AlertmanagerConfig = WHO is paged (team → e-mail routes)        │
   └──────────────────────────────────────────────┬───────────────────────────────────────────────┘
                                                   │  (operator selects + merges)
   ┌───────────────────────────────── central (kube-prometheus-stack) ─────────────────────────────┐
   │  Alertmanager base config = HOW e-mail is sent — Amazon SES smarthost + auth + TLS + From      │
   │  (the single place the SMTP gateway/credentials live)                                          │
   └────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Concern | Lives in | Kind |
|---|---|---|
| **What to alert on** | `app-monitoring/values-<app>.yaml` → rendered | `PrometheusRule` |
| **Who is paged** (team → e-mail, severity routing) | same values → rendered | `AlertmanagerConfig` |
| **How e-mail is sent** (SES host, auth, TLS, From) | `values/kube-prometheus-stack.yaml` | Alertmanager global config |

**Why this split:** adding or changing an app's alerting is a single `helm upgrade` of that app's
release — no change to the central stack. The transport (SES credentials) is configured once.

---

## The per-application chart

`app-monitoring/` is a tiny Helm chart. You describe one application in a values file and it renders
the two CRs. Copy `values.yaml` to `values-<app>.yaml`:

```yaml
app:
  name: bankobs
  namespace: monitoring        # CRs go where Prometheus/Alertmanager run (the obs cluster)

teams:
  - name: platform
    emails: ["platform-sre@example.com"]
  - name: payments
    emails: ["payments-eng@example.com"]
    criticalEmails: ["payments-oncall@example.com"]   # severity=critical routes here
defaultTeam: platform

enableTestAlert: false          # true = add an always-firing probe to test the pipeline

alerts:
  - name: BankobsPodNotRunning
    team: platform
    severity: critical          # critical|warning|info
    for: 5m
    expr: 'count(k8s_pod_phase{k8s_cluster_name="obs-v1-bankobs",k8s_namespace_name="bankobs"} == 1) > 0'
    summary: "BankObs has pods not in Running state"
    description: "{{ $value }} pod(s) are not Running."     # Prometheus templating, written literally
```

- **`expr`** is raw PromQL over the metrics already in Prometheus. Because metrics are OTel-only, use
  the **OTel-native names**: `k8s_pod_phase` (value 1=Pending 2=Running 3=Succeeded 4=Failed 5=Unknown),
  `k8s_container_restarts`, `k8s_pod_cpu_usage`, `k8s_pod_memory_working_set_bytes`,
  `k8s_deployment_desired`/`_available`; and the spanmetrics RED series `calls_total` /
  `duration_milliseconds_bucket` (labels `service_name`, `service_namespace`, `status_code`). Every
  series carries `k8s_cluster_name` so you can target a cluster.
- Each rule is auto-labelled `app`, `team`, `severity`. **Routing matches those labels** — the
  `AlertmanagerConfig` sends `team=payments` alerts to the payments receiver, and `severity=critical`
  within it to the team's `criticalEmails`.
- `{{ $value }}` / `{{ $labels.x }}` in `summary`/`description` are **Prometheus** templating. Helm
  does not touch values, so they pass straight through.

The worked example is `app-monitoring/values-bankobs.yaml` (two teams, five real alerts).

**Add another app:** write `values-foo.yaml`, then
`helm upgrade --install foo-monitoring ./app-monitoring -n monitoring -f app-monitoring/values-foo.yaml`.

---

## Amazon SES setup (how e-mail is sent)

### 1. Get SES SMTP credentials and verify a sender
In the SES console (region `us-east-1`):
- **SMTP settings → Create SMTP credentials** → you receive an **SMTP username** and **SMTP password**
  (the SMTP password is *not* your AWS secret key).
- **Verified identities →** verify the **From** domain or address (e.g. `observability-alerts@lab.example.com`).
  If your SES account is still in the **sandbox**, also verify each **recipient** address, or request
  production access.

### 2. Point the config at your region / sender
In `values/kube-prometheus-stack.yaml` the global block is pre-set to
`email-smtp.us-east-1.amazonaws.com:587` with STARTTLS. Change the region host and `smtp_from` if
needed (or pass `SES_FROM=` at deploy).

### 3. Store the credentials (never in git)
```bash
make alertmanager-secret SES_SMTP_PASSWORD='<ses-smtp-password>'     # → Secret alertmanager-ses-smtp
```
The password is mounted into Alertmanager and referenced as `smtp_auth_password_file`. The **username**
and **From** are injected at deploy via `--set-string`:
```bash
make kube-prometheus-stack SES_SMTP_USERNAME='AKIA…SES' SES_FROM='observability-alerts@lab.example.com'
```
(For GitOps, `alertmanager/ses-smtp-secret.example.yaml` is the manifest form — feed it through
sealed-secrets/SOPS, don't commit a real password.)

---

## Deploy

On top of an existing stack (metrics/traces/logs already running — the cluster stays as-is):

```bash
# 1. store SES creds + apply the Alertmanager transport
make alertmanager-secret SES_SMTP_PASSWORD='<pw>'
make kube-prometheus-stack SES_SMTP_USERNAME='<user>' SES_FROM='alerts@you.com'

# 2. apply the per-app alerting CRDs
make app-monitoring
```

`make all …` runs the whole stack in order and includes both steps automatically.

---

## Verify end-to-end

```bash
CTX=obs-v1-observability

# PrometheusRule loaded by Prometheus:
kubectl --context $CTX -n monitoring exec deploy/kps-grafana -c grafana -- \
  curl -s 'http://kps-prometheus:9090/api/v1/rules' | grep -o 'Bankobs[A-Za-z]*' | sort -u

# AlertmanagerConfig merged (receivers visible):
kubectl --context $CTX -n monitoring exec alertmanager-kps-alertmanager-0 -c alertmanager -- \
  amtool config show --alertmanager.url=http://localhost:9093 | grep -A2 'name: .*bankobs'
```

**Fire a real test** (sends you a probe e-mail, then turn it off):

```bash
helm --kube-context $CTX upgrade --install bankobs-monitoring ./app-monitoring -n monitoring \
  -f app-monitoring/values-bankobs.yaml --set enableTestAlert=true
# → within ~1 min: alert BankobsAlertPipelineTest fires → routed to the platform receiver → SES e-mail
# watch it leave:
kubectl --context $CTX -n monitoring logs alertmanager-kps-alertmanager-0 -c alertmanager | grep -i 'smtp\|email\|notify'
# then disable:
helm --kube-context $CTX upgrade --install bankobs-monitoring ./app-monitoring -n monitoring \
  -f app-monitoring/values-bankobs.yaml --set enableTestAlert=false
```

If the logs show an SMTP **auth** error, the pipeline is correct but the SES username/password/From
aren't right yet — recheck step 2/3 above and that the From identity is verified (and recipients, if
in the SES sandbox).

---

## Files

| File | Role |
|---|---|
| `values/kube-prometheus-stack.yaml` | Alertmanager base config — **SES transport** + config-CR selectors |
| `app-monitoring/` (chart) | renders `PrometheusRule` + `AlertmanagerConfig` per app |
| `app-monitoring/values-bankobs.yaml` | worked example (2 teams, 5 alerts) |
| `alertmanager/ses-smtp-secret.example.yaml` | manifest form of the SES password secret (GitOps) |
| `Makefile` | `alertmanager-secret`, `app-monitoring`, wired into `all`/`destroy` |

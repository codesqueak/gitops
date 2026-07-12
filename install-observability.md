# Installing the Observability Stack

This guide covers standing up the full LGTM observability stack (SeaweedFS, Mimir, Loki, Tempo, Grafana, Alloy, kube-state-metrics, node-exporter) on a dev cluster and validating it end-to-end. It covers only the components deployed via ArgoCD.

## Components

| Component | Helm chart | Responsibilities |
|-----------|-----------|-------------------|
| SeaweedFS | `seaweedfs/seaweedfs` (all-in-one mode) | S3-compatible object storage backend for Mimir, Loki and Tempo — same API as AWS S3 so backend config is identical between dev and prod |
| Mimir | `grafana/mimir-distributed` | Metric storage, long-term retention, PromQL query support |
| Loki | `grafana/loki` (distributed mode) | Log storage, LogQL queries, Kubernetes log aggregation |
| Tempo | `grafana/tempo-distributed` | Distributed trace storage, trace search, service dependency analysis |
| Grafana | `grafana/grafana` | Dashboards, alerting, metrics/logs/traces exploration; data sources for Mimir, Loki, Tempo |
| kube-state-metrics | `prometheus-community/kube-state-metrics` | Deployment status, replica counts, pod state, job state, HPA metrics |
| prometheus-node-exporter | `prometheus-node-exporter` | CPU, memory, disk, network metrics |
| Alloy | `grafana/alloy` | OTLP ingestion, log collection, metric scraping, forwarding to Mimir, Loki and Tempo |

Repository structure:

```text
gitops-repo/
├── bootstrap/
├── observability/
│   ├── apps/
│   ├── grafana/
│   ├── seaweedfs/
│   ├── mimir/
│   ├── loki/
│   ├── tempo/
│   ├── alloy/
│   ├── kube-state-metrics/
│   └── node-exporter/
└── applications/
    └── dev/
```

## Prerequisites

- kind cluster running
- ArgoCD installed in the `argocd` namespace
- This repo cloned and pushed to GitHub (ArgoCD pulls from `https://github.com/codesqueak/gitops.git`)

### Host inotify limits

kind nodes are containers sharing the host kernel's inotify accounting — it is not namespaced per-container. A full LGTM stack (Loki, Mimir, Tempo, Alloy, Grafana) runs enough pods with fsnotify-based config/cert watchers to exceed the Linux default `fs.inotify.max_user_instances` (128) quickly; on this cluster usage reached ~1823 instances.

Once exhausted, the failure is **not confined to observability pods**. `kube-proxy` on the affected node crashes with `too many open files`, which breaks Service/ClusterIP and DNS routing for every other pod on that node — so ArgoCD, ingress-nginx, MetalLB, and any observability component scheduled there will crash-loop too, each with a different-looking symptom (i/o timeouts to the apiserver, DNS resolution failures, memberlist gossip failures, etc.).

Raise the limits on the actual Docker/kind host before installing (must be run on the host, not via `docker exec` into a node — the setting is shared, but only persists if applied at the host level):

```bash
sudo tee /etc/sysctl.d/99-kind-inotify.conf <<'CONF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
CONF
sudo sysctl --system
```

If pods are already crash-looping with `too many open files`, check current usage against the limit:

```bash
sudo sh -c 'grep -c "^inotify" /proc/[0-9]*/fdinfo/* 2>/dev/null | awk -F: "{s+=\$2} END{print s}"'
```

If usage is close to or above `max_user_instances`, raise the limit further and re-apply.

## 1. Bootstrap ArgoCD

Apply the root app and all AppProjects. These are not managed by ArgoCD itself — they must be applied manually.

```bash
kubectl apply -f gitops-repo/bootstrap/observability-project.yaml
kubectl apply -f gitops-repo/bootstrap/infrastructure-project.yaml
kubectl apply -f gitops-repo/bootstrap/root-app.yaml
```

The root app watches `gitops-repo/applications/dev` and will auto-create the `observability` and `infrastructure` app-of-apps, which in turn deploy all stack components.

## 2. Wait for components to deploy

The stack deploys in sync waves to ensure dependencies are ready before dependents start:

| Wave | Components |
|------|------------|
| -3   | SeaweedFS |
| -2   | Mimir, Loki, Tempo |
| -1   | Grafana |
|  0   | kube-state-metrics, node-exporter |
|  1   | Alloy |

Monitor progress:

```bash
kubectl get pods -n observability -w
```

Full readiness takes 3–5 minutes. All pods should reach `1/1 Running` or `2/2 Running`. Expected pod count is approximately 30.

> **Note:** Loki's `zoneAwareReplication` is disabled in `gitops-repo/observability/loki/values/dev.yaml` (see [Configuration Reference](#configuration-reference) below), so the chart renders a single `loki-ingester` StatefulSet rather than `loki-ingester-zone-a/b/c`. If you see zone-suffixed ingester pods stuck `Pending`, the values file has drifted from this setting — check it before assuming the cluster is at fault.

If any pods are stuck, check ArgoCD sync status — see the [Debugging](#debugging) section at the end of this guide.

## 3. Configure /etc/hosts

The infrastructure stack deploys MetalLB and ingress-nginx. Once ingress-nginx gets its LoadBalancer IP from MetalLB, add the hostnames to your local `/etc/hosts`:

```bash
# Get the assigned IP
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Add to /etc/hosts (expected IP is 172.20.255.200)
echo "172.20.255.200  grafana.local argocd.local" | sudo tee -a /etc/hosts
```

## 4. Access Grafana and ArgoCD

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | `http://grafana.local` | admin / admin |
| ArgoCD  | `https://argocd.local` | admin / see below |

ArgoCD initial admin password:

```bash
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## 5. Validate datasources

Datasources are provisioned via Helm values and are **read-only in the Grafana UI**. If a test fails and you need to change an endpoint, edit `gitops-repo/observability/grafana/values/dev.yaml` and commit — do not try to edit them in the browser.

Go to **Connections → Data Sources** and click **Test** on each datasource:

- **Mimir** — should return green
- **Loki** — should return green
- **Tempo** — should return green

## 6. Validate telemetry

**Metrics (Mimir)**

Go to **Explore**, select the **Mimir** datasource, switch to Code mode, and run:

```
up
```

You should see time series from `kube-state-metrics` and `node-exporter`.

**Logs (Loki)**

Go to **Explore**, select **Loki**, and run:

```
{namespace="observability"}
```

You should see log streams from the observability pods.

**Traces (Tempo)**

Go to **Explore**, select **Tempo**, and use the **Search** tab to look for recent traces. Traces will only appear once a Spring Boot service instrumented with OpenTelemetry is sending data through Alloy.

## 7. Pre-built dashboards

Grafana comes up with five community dashboards pre-provisioned (see [Pre-built dashboards](#pre-built-dashboards) below for what and why). Go to **Dashboards** and confirm all five are listed:

- Node Exporter Full
- Kubernetes / Views / Global
- JVM (Micrometer)
- Logs / App
- K8S Dashboard for Alloy Metrics exported to Mimir - Microservices Overview

None of the five rendered correct data out of the box — provisioning without errors is not the same as showing correct data. See [Dashboard fixes](#dashboard-fixes) below for what was wrong with each one and how it was resolved; that section is worth reading before assuming a blank panel means your cluster is broken.

## Configuration Reference

### Loki retention

Configured in `gitops-repo/observability/loki/values/dev.yaml` under the `loki:` key:

```yaml
loki:
  limits_config:
    retention_period: 336h   # 14 days

  compactor:
    retention_enabled: true
    delete_request_store: s3
```

- `limits_config.retention_period` sets the global retention window (logs older than this are eligible for deletion).
- `compactor.retention_enabled` must be `true` for the compactor to actually enforce retention — otherwise `retention_period` is recorded but never acted on.
- `compactor.delete_request_store` must match `storage.type`/`object_store` (here `s3`, backed by SeaweedFS) — the compactor needs somewhere to persist delete request markers.
- The compactor workload itself (top-level `compactor.replicas` in the same values file) must be `>= 1` — retention deletion is performed by the compactor's regular compaction cycle, no separate job is needed.
- Verify a values change renders correctly before syncing: `helm template loki grafana/loki --version <chart-version> -f gitops-repo/observability/loki/values/dev.yaml | grep -A3 retention_period`

### Loki zone awareness

The `grafana/loki` chart defaults to `ingester.zoneAwareReplication.enabled: true`, which enforces hard pod anti-affinity requiring each zone's ingester (`zone-a`, `zone-b`, `zone-c`) to run on a distinct node. On a small dev cluster (e.g. kind with one control-plane node and one worker node), only one zone can ever be scheduled — the rest sit `Pending` with `didn't match pod anti-affinity rules` / `untolerated taint`.

Since this dev config already runs with `commonConfig.replication_factor: 1` (no real redundancy expected), zone-awareness provides no benefit here and is disabled in `gitops-repo/observability/loki/values/dev.yaml`:

```yaml
ingester:
  replicas: 1
  zoneAwareReplication:
    enabled: false
```

Note `ingester:` is a top-level values key in this chart (alongside `distributor:`, `querier:`, etc.), not nested under `loki:`.

With this disabled, the chart renders a single `loki-ingester` StatefulSet instead of `loki-ingester-zone-a/b/c`. Confirm with:

```bash
helm template loki grafana/loki --version <chart-version> -f gitops-repo/observability/loki/values/dev.yaml | grep -E "^kind: StatefulSet$|name: loki-ingester"
```

### Pre-built dashboards

Configured in `gitops-repo/observability/grafana/values/dev.yaml` under `dashboards:`, with `dashboardProviders:` set to a single `type: file` provider watching `/var/lib/grafana/dashboards/default`.

The Grafana chart's `download-dashboards` init container fetches each dashboard's JSON from grafana.com on pod start using the `gnetId`/`revision` pair, then does an in-place substitution of every panel's `datasource` field to point at the name given — so `datasource: Mimir` and `datasource: Loki` must match the `name:` fields under the `datasources:` block (not the `uid:` values), or the substitution silently no-ops and panels come up with no data source selected.

| Dashboard | gnetId | Why |
|---|---|---|
| Node Exporter Full | 1860 | The de-facto standard dashboard for `node-exporter` host metrics (CPU, memory, disk, network) — most widely used dashboard in the ecosystem, so no reason to build a custom one |
| Kubernetes / Views / Global | 15757 | Cluster/namespace/pod resource view built on `kube-state-metrics`, actively maintained (dotdc/grafana-dashboards-kubernetes), designed for kube-prometheus-stack but works unmodified against Mimir since it's Prometheus-compatible |
| JVM (Micrometer) | 4701 | Heap, GC, thread pool metrics for Micrometer-instrumented apps — directly relevant since this project's services are Spring Boot 4. Required both app-side and dashboard-side fixes — see [Dashboard fixes](#dashboard-fixes) |
| Logs / App | 13639 | Generic Loki log viewer (filter by namespace/pod/container) — covers ad-hoc log browsing without needing to hand-write LogQL in Explore every time |
| K8S Dashboard for Alloy Metrics exported to Mimir - Microservices Overview | 24685 | Specifically built for the Alloy → Mimir path this stack uses, rather than a generic Prometheus/node-exporter dashboard repurposed for Alloy |

Revisions are pinned (not left to float to "latest") for the same reason chart versions are pinned — an unannounced dashboard JSON change on grafana.com shouldn't be able to silently change what a synced dev environment renders. Check for newer revisions periodically:

```bash
curl -s https://grafana.com/api/dashboards/<gnetId>/revisions | jq '.items[-1].revision'
```

Tempo intentionally has no pre-built dashboard here — trace exploration is normally done via Grafana's **Explore** + **Search** UI and the Tempo service graph (already wired up via `serviceMap.datasourceUid` in the Tempo datasource config), not a static dashboard.

### Dashboard fixes

None of the five dashboards worked correctly out of the box, even though all five provisioned into Grafana without error. **"Provisioned successfully" is not the same as "shows correct data"** — every one of them was built against a differently-configured Grafana/Prometheus/Loki environment than this stack actually runs. Fixes fell into two categories:

- **Infra-side**: the dashboard JSON itself is fine; Alloy's scrape/relabel config was missing something the dashboard's queries depend on. No dashboard fork needed.
- **Dashboard-side**: the dashboard's queries themselves assume a datasource UID, label, or metric-naming convention this stack doesn't produce. Fixed by forking the JSON into `gitops-repo/observability/grafana/dashboards/` and provisioning it via the chart's `url:` + slice-form `datasource:` mechanism instead of a live `gnetId` pull (see the table above for how that substitution works).

| Dashboard | Problem | Fix | Forked? |
|---|---|---|---|
| Node Exporter Full | Blank — Alloy's node-exporter scrape target used the wrong Kubernetes Service DNS name (`prometheus-node-exporter...` instead of the chart's actual `node-exporter-prometheus-node-exporter...` fullname) | Corrected the scrape target address in `gitops-repo/observability/alloy/values/dev.yaml` | No |
| Kubernetes / Views / Global | Per-pod/per-container CPU, memory and network panels (roughly half the dashboard) blank — Alloy only scraped `kube-state-metrics` and `node-exporter`, never the kubelet's cAdvisor endpoint that `container_*`/`machine_*` metrics come from | Added `discovery.kubernetes` (role=node) + `discovery.relabel` + `prometheus.scrape "cadvisor"` to Alloy, scraping each node's kubelet directly at `:10250/metrics/cadvisor` using the pod's own service-account bearer token (the chart's default ClusterRole already grants the `nodes/metrics` permission this requires) | No |
| JVM (Micrometer) | Blank/partially blank for two independent reasons. **App-side**: Micrometer's OTLP metrics registry defaulted to pushing to `localhost:4318` (nothing listens there — Alloy is a separate pod), and even once pointed at Alloy, its Service didn't expose the OTLP ports (4317/4318) it listens on internally, only its debug port (12345) — so traces were silently broken too, not just this. **Dashboard-side**: this dashboard assumes the classic `micrometer-registry-prometheus` naming convention, which doesn't match the OTel-derived names/units this stack's `spring-boot-starter-opentelemetry` → Alloy → Mimir path actually produces — e.g. `jvm_threads_live_threads` vs. the real `jvm_threads_live`, `jvm_gc_pause_seconds_*` vs. the real `jvm_gc_pause_milliseconds_*`. Metrics also had no `application` label at all (Spring Boot doesn't add it automatically), so the dashboard's app picker resolved to empty | **App**: added `management.otlp.metrics.export.url` and `management.metrics.tags.application` to the service's `application.properties`. **Infra**: added `alloy.extraPorts` (4317, 4318) in `gitops-repo/observability/alloy/values/dev.yaml` so Alloy's Service exposes what it already listens on. **Dashboard**: forked into `gitops-repo/observability/grafana/dashboards/jvm-micrometer.json` with every affected query renamed/rescaled to the real metric names; the GC "max pause" panel has no direct equivalent under OTel's histogram-based export and is approximated with `histogram_quantile(1.0, ...)` | Yes |
| Logs / App | The `app` picker had exactly one (useless) option, and selecting it dumped every pod's logs from the whole cluster together — every pod got the same literal `job` label (the Alloy component's own name), because `loki.source.kubernetes "pods"` had no relabeling to turn Kubernetes discovery metadata into real labels | Added a `discovery.relabel "pods"` step in Alloy promoting `namespace`/`pod`/`container` into real labels and deriving `job = namespace/container` per pod | No |
| K8S Dashboard for Alloy Metrics exported to Mimir (Microservices Overview) | Every panel hardcoded the original author's Mimir datasource UID via the newer multi-line `"datasource": {"type": ..., "uid": ...}` object form, which the chart's plain-string `datasource: Mimir` substitution can't rewrite (it needs the whole field on one line). Also filtered on a `cluster` label that `kube-state-metrics` doesn't set natively. Its Persistent Volume panels (`kubelet_volume_stats_*`) were also blank — that metric comes from kubelet's separate main `/metrics` endpoint, which Alloy wasn't scraping (only `/metrics/cadvisor`) | Forked into `gitops-repo/observability/grafana/dashboards/alloy-k8s-microservices.json` with every UID replaced by a `${MIMIR_UID}` token, resolved via the chart's slice-form `datasource:` substitution instead. Added `external_labels = { "cluster" = "dev" }` to Alloy's `prometheus.remote_write` block. Added a second node scrape (`discovery.relabel "kubelet"` + `prometheus.scrape "kubelet"`, same node-IP:10250 pattern as cadvisor, just `__metrics_path__ = "/metrics"`) for the volume-stats metrics | Yes |

If a panel is blank after all of the above, check in this order: (1) does the underlying metric/log/trace exist at all in Mimir/Loki (query it directly in **Explore**), (2) do the dashboard's template variables (top-left dropdowns) actually resolve to a value, (3) does the panel's query use a metric/label name that matches what's really being produced — don't assume a community dashboard's naming matches this stack's until you've checked.

### Panels that are blank by design, not by bug

A few panels across these dashboards will **never** show data on this stack, regardless of Alloy config. Don't spend time debugging these — they're either environmental limitations or leftovers from the original dashboard author's setup:

| Dashboard | Panel(s) | Why it's permanently blank |
|---|---|---|
| K8S Dashboard for Alloy Metrics exported to Mimir | Persistent Volume usage/capacity | `kubelet_volume_stats_*` requires the volume plugin to implement kubelet's stats-collection interface. This cluster's `standard` StorageClass uses `rancher.io/local-path`, a legacy non-CSI provisioner that doesn't support it. Fixing this needs a CSI-based storage driver, not an Alloy change |
| K8S Dashboard for Alloy Metrics exported to Mimir | Cassandra JVM heap panels (`cass_jvm_heap`, `cass_jvm_heap_max`) | Leftover from the original dashboard author's environment — this project doesn't run Cassandra anywhere |
| Kubernetes / Views / Global | Any `windows_*`-prefixed panel | Dashboard supports both Linux and Windows nodes; this cluster is Linux-only, so the Windows collector metrics never exist |
| Node Exporter Full | Panels backed by `node_systemd_units`, `node_processes_*`, or similarly niche collectors | `prometheus-node-exporter`'s systemd and processes collectors are disabled by default (not every node-exporter collector runs out of the box) — enable the relevant `--collector.*` flag in `gitops-repo/observability/node-exporter/values/dev.yaml` if you actually need one of these |
| JVM (Micrometer) | Process memory (RSS/VSS/swap) and process thread count panels | These meters aren't part of Micrometer core or Spring Boot's auto-registered binders — they come from a separate add-on library, `io.github.mweirauch:micrometer-jvm-extras` (`ProcessMemoryMetrics`/`ProcessThreadMetrics`). Tried adding it as an explicit `MeterBinder` bean in `motd` (2026-07-10) and confirmed it registers correctly under a plain local JVM (Eclipse Temurin), but silently registers **nothing** when run as the actual deployed container image — reproduced outside Kubernetes too (plain `docker run` of the built image), so it's not a Kubernetes/securityContext/RBAC issue. `/proc/self/status` and the relevant cgroup files are confirmed readable inside the container either way. The one remaining difference is the JRE: the deployed image runs Paketo's default **BellSoft Liberica** JRE, not Temurin — this looks like a genuine incompatibility between that library's procfs-reading approach and BellSoft Liberica specifically. Reverted the dependency rather than chase it further for 4 supplementary metrics that don't affect the rest of the dashboard |

**Metric-naming mismatches specifically** (the JVM dashboard's core problem — dashboard queries assuming different metric names/units than what's actually produced) were checked across all five dashboards, not just JVM. Node Exporter Full, Kubernetes / Views / Global, and the Alloy K8S Microservices dashboard are all sourced from metrics that Alloy scrapes directly via `prometheus.scrape` (`node-exporter`, `kube-state-metrics`, cAdvisor, kubelet) — these pass through unmodified, with no naming translation step, so there's no way for this specific class of bug to occur there; live metric names were spot-checked against each dashboard's queries and all matched. The JVM dashboard is the only one of the five whose data arrives via an OTLP-instrumented app pushing through Alloy's OTel→Prometheus converter, which is what introduces the naming/unit differences — worth remembering if more OTLP-instrumented dashboards are added later.

### Helm chart version management

Before installing or upgrading, verify the pinned chart versions in `gitops-repo/observability/apps/` are valid.

Add Helm repos:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Check latest available versions:

```bash
helm search repo grafana/mimir-distributed
helm search repo grafana/loki
helm search repo grafana/tempo-distributed
helm search repo grafana/grafana
helm search repo grafana/alloy
helm search repo seaweedfs/seaweedfs
helm search repo prometheus-community/kube-state-metrics
helm search repo prometheus-community/prometheus-node-exporter
```

Before syncing, dry-run a template render to catch any values key mismatches:

```bash
helm template <release-name> <repo>/<chart> \
  --version <chart-version> \
  -f gitops-repo/observability/<component>/values/dev.yaml
```

Major version bumps often include breaking changes to values key names. Check the chart changelog with:

```bash
helm show values <repo>/<chart> --version <chart-version>
```

## Initial Alerting

Create alerts for:

- Service unavailable
- High error rate
- High latency
- Pod restart storm
- Node memory pressure
- Node disk pressure

## Production Tasks

- Configure SSO for Grafana
- Replace SeaweedFS with real S3 object storage (update endpoint and credentials in Mimir, Loki and Tempo config)
- Configure retention policies
- Configure backups
- Store secrets outside Git
- Pin Helm chart versions

## Troubleshooting

**Mimir pods crashing with "bucket does not exist"**

The Mimir Helm chart includes a bundled MinIO subchart (`mimir-minio`) which is enabled by default. When enabled, it overrides the storage configuration and causes Mimir to connect to `mimir-minio` instead of the standalone SeaweedFS — which doesn't have the right buckets. The values already have `minio.enabled: false` to prevent this, but if you see this error verify that setting is in place in `gitops-repo/observability/mimir/values/dev.yaml`.

If the setting is correct but the error persists, the SeaweedFS bucket-creation hook Job may not have run. Exec into the SeaweedFS pod to create the buckets manually (the S3-compatible CLI here is `mc`, MinIO's client, which works against any S3-compatible endpoint including SeaweedFS):

```bash
SEAWEEDFS_POD=$(kubectl get pod -n observability -l app.kubernetes.io/component=seaweedfs-all-in-one -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n observability $SEAWEEDFS_POD -- /bin/bash -c \
  "mc alias set local http://localhost:8333 seaweedfsadmin seaweedfsadmin && \
   mc mb local/mimir-blocks && \
   mc mb local/mimir-ruler && \
   mc mb local/mimir-alertmanager"
```

Then delete the crashing pods to force an immediate restart:

```bash
kubectl delete pod -n observability mimir-ingester-0 mimir-compactor-0 \
  mimir-alertmanager-0 mimir-store-gateway-0 mimir-ruler-0
```

**Alloy sync error — CustomResourceDefinition not permitted**

If the `alloy` ArgoCD app fails with a CRD permission error, the AppProject change may not have been applied yet:

```bash
kubectl apply -f gitops-repo/bootstrap/observability-project.yaml
argocd app sync alloy
```

**ArgoCD sync stuck with "another operation is already in progress"**

```bash
argocd app terminate-op <app-name>
argocd app sync <app-name> --prune
```

**ingress-nginx sync error — IngressClass or ValidatingWebhookConfiguration not permitted**

The infrastructure AppProject whitelist must include these cluster-scoped resource types. If missing, apply the updated AppProject:

```bash
kubectl apply -f gitops-repo/bootstrap/infrastructure-project.yaml
argocd app sync ingress-nginx
```

**App-of-apps permanently OutOfSync — diff shows nothing**

If the `observability` app shows all child apps as OutOfSync but `argocd app diff` returns nothing, the cause is likely `spec.description` on the Application manifests. The ArgoCD CRD schema does not include this field, so Kubernetes strips it from the stored resource on every apply. ArgoCD then detects a perpetual diff between git (which has the field) and the live resource (which doesn't).

The fix is to remove `description:` from all Application manifests in `gitops-repo/observability/apps/` and `gitops-repo/applications/dev/observability.yaml`. The field has no functional effect — component descriptions are documented in this guide instead.

---

## Debugging

### Install the ArgoCD CLI

```bash
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
```

### Access the ArgoCD UI

Port-forward the ArgoCD server:

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

Open `https://localhost:8080`. Username is `admin`, get the password with:

```bash
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Log in via CLI

```bash
argocd login localhost:8080 --insecure
```

### ArgoCD commands

```bash
# List all applications and their sync/health status
argocd app list

# Show detailed status and resource list for an app
argocd app get <app-name>

# Manually trigger a sync
argocd app sync <app-name>

# Sync and remove resources no longer in git
argocd app sync <app-name> --prune

# Kill a stuck sync operation
argocd app terminate-op <app-name>

# Stream live logs from an app's sync operation
argocd app logs <app-name>
```

> **Note:** The AppProject (`observability-project.yaml`) and root app (`root-app.yaml`) are not managed by ArgoCD — changes to these must be applied with `kubectl apply`, not `argocd app sync`.

### Kubernetes commands

**Pod status**

```bash
# Watch all observability pods
kubectl get pods -n observability -w

# Filter to a specific component
kubectl get pods -n observability | grep mimir
kubectl get pods -n observability | grep loki
kubectl get pods -n observability | grep tempo
kubectl get pods -n observability | grep alloy
```

**Logs**

```bash
# Logs from a running pod
kubectl logs -n observability <pod-name>

# Logs from the previous (crashed) container instance
kubectl logs -n observability <pod-name> --previous

# Tail logs from a deployment
kubectl logs -n observability deployment/<name> --tail=50

# Stream logs from all pods with a label
kubectl logs -n observability -l app.kubernetes.io/name=alloy -f
```

**Describe a pod** (shows events, resource limits, restart reasons)

```bash
kubectl describe pod -n observability <pod-name>
```

**Services**

```bash
# List all services in the observability namespace
kubectl get svc -n observability

# Check a specific service's ports
kubectl get svc -n observability <service-name>
```

**Jobs** (useful for checking SeaweedFS bucket creation)

```bash
kubectl get jobs -n observability
kubectl logs -n observability job/<job-name>
```

**Port-forwarding to internal services**

```bash
# Grafana
kubectl port-forward -n observability svc/grafana 3000:80

# SeaweedFS S3 API
kubectl port-forward -n observability svc/seaweedfs-all-in-one 8333:8333

# ArgoCD
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

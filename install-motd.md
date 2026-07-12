# Installing the motd and motd-ui Services

This guide covers deploying `motd` (a Spring Boot backend) and `motd-ui` (a React frontend) end to end,
and is intended as a worked example for adding any future application service to this project. Unlike
[install-observability.md](install-observability.md), which deploys third-party charts pulled straight
from public Helm repos, `motd` and `motd-ui` are first-party services: each lives in its own GitHub repo,
builds its own container image via GitHub Actions, and pushes updated image tags into this gitops repo
automatically. This doc covers that whole loop, not just the Kubernetes side.

## Components

| Component | Repo | Language/build | Image | Chart |
|-----------|------|-----------------|-------|-------|
| motd | `codesqueak/motd` | Spring Boot 4, Gradle, Paketo buildpacks (`bootBuildImage`) | `ghcr.io/codesqueak/motd` | `gitops-repo/charts/motd` |
| motd-ui | `codesqueak/motd-ui` | React + Vite + TypeScript, served via nginx | `ghcr.io/codesqueak/motd-ui` | `gitops-repo/charts/motd-ui` |

`motd` exposes a small REST API (`GET /api/motd`, `GET /api/motd/count`) plus Spring Boot Actuator health
endpoints. `motd-ui` is a static SPA whose nginx config reverse-proxies `/api/` to the `motd` Service -
there's no server-side rendering or separate backend-for-frontend, nginx does the routing directly.

## Repository structure

```text
github.com/codesqueak/motd          # Spring Boot source + Dockerfile-equivalent (buildpacks) + CI
github.com/codesqueak/motd-ui       # React source + Dockerfile + nginx.conf + CI
github.com/codesqueak/gitops        # this repo - Helm charts + environment values + ArgoCD Applications
└── gitops-repo/
    ├── applications/dev/motd.yaml       # ArgoCD Application: chart + values file for motd
    ├── applications/dev/motd-ui.yaml    # ArgoCD Application: chart + values file for motd-ui
    ├── charts/motd/                     # Helm chart (Deployment, Service)
    ├── charts/motd-ui/                  # Helm chart (Deployment, Service, ConfigMap, Ingress)
    └── environments/dev/
        ├── motd-values.yaml             # image.tag override - written by motd's CI, not by hand
        └── motd-ui-values.yaml          # image.tag override - written by motd-ui's CI, not by hand
```

## How the pipeline works

This is the part that makes `motd`/`motd-ui` different from the observability stack: there's a closed
loop from `git push` to a running pod, with no manual image tag editing.

1. A developer pushes to `main` (or a `v*.*.*` tag) on `codesqueak/motd` or `codesqueak/motd-ui`.
2. GitHub Actions (`.github/workflows/build-publish.yml`) runs: tests, then builds the container image
   (`./gradlew bootBuildImage` for motd; `docker build` for motd-ui) and pushes it to
   `ghcr.io/codesqueak/<repo>:<7-char-sha>`.
3. The workflow clones `codesqueak/gitops` using a `GITOPS_PAT` repo secret (a PAT with write access to
   this repo - already provisioned on both app repos), `sed`-replaces the `image.tag` line in the
   matching `environments/dev/<service>-values.yaml`, commits, and pushes.
4. ArgoCD's `motd-dev`/`motd-ui-dev` Applications have `syncPolicy.automated` with `selfHeal: true`, so
   they pick up that commit on their next poll (default ~3 min) and roll the new image out via Helm.

No manual `kubectl set image` or chart edit is ever needed for a routine app change - only the app repo's
`main` branch. See [Troubleshooting](#troubleshooting) below for how to speed step 4 up if you don't want
to wait for the poll interval.

## Prerequisites

- kind cluster, ArgoCD, and the `infrastructure` app (MetalLB + ingress-nginx) already bootstrapped - see
  [install-kubernetes.md](install-kubernetes.md) and [install-observability.md](install-observability.md).
- `motd` and `motd-ui` repos each have a `GITOPS_PAT` repository secret set (see step 3 above).
- `ghcr.io/codesqueak/motd` and `ghcr.io/codesqueak/motd-ui` packages are public. Both charts already
  reference `imagePullSecrets: ghcr-credentials`, but that secret doesn't need to exist while the packages
  are public - see [TODO.md](TODO.md) if that ever changes.

## 1. Bootstrap ArgoCD

If `observability`/`infrastructure` are already running, this is done - `motd.yaml` and `motd-ui.yaml`
live in the same `gitops-repo/applications/dev` directory as `observability.yaml`, so the `root` app
already manages them. Nothing extra to apply.

Deploying standalone (no observability stack yet)? The same root-app bootstrap from
[install-observability.md](install-observability.md#1-bootstrap-argocd) covers it - `root` watches the
whole `applications/dev` directory, so `motd-dev` and `motd-ui-dev` Applications get created alongside
whatever else is in there:

```bash
kubectl apply -f gitops-repo/bootstrap/projects.yaml
kubectl apply -f gitops-repo/bootstrap/root-app.yaml
```

## 2. Wait for components to deploy

```bash
kubectl get pods -n app-motd-dev -w
kubectl get pods -n app-motd-ui-dev -w
```

Both namespaces are created automatically (`syncOptions: [CreateNamespace=true]` on each Application).
Each service is a single Deployment/Service pair - readiness is typically under a minute, much faster
than the observability stack.

## 3. Configure /etc/hosts

`motd-ui` is exposed via the same ingress-nginx LoadBalancer IP as Grafana and ArgoCD:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo "172.20.255.200  motd-ui.local" | sudo tee -a /etc/hosts
```

(If you already added `grafana.local`/`argocd.local` per install-observability.md, just append
`motd-ui.local` to that same line.)

## 4. Access motd-ui

Open `http://motd-ui.local` - you should see a random message of the day, refreshed on each page load.

## 5. Validate the service

Directly through the ingress (mirrors exactly what the browser does):

```bash
curl http://motd-ui.local/api/motd
# {"text":"Message A"}

curl http://motd-ui.local/api/motd/count
# {"count":3}
```

Backend health, from inside the cluster:

```bash
kubectl exec -n app-motd-ui-dev deploy/motd-ui-dev -- wget -qO- \
  http://motd-dev.app-motd-dev.svc.cluster.local:8000/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}
```

## 6. Verify telemetry (optional)

`motd` is instrumented with OpenTelemetry out of the box (`management.otlp.*` in
`application.properties`), pushing metrics/traces/logs to Alloy. Once the observability stack is up:

- **Metrics**: Grafana → Explore → Mimir → `jvm_threads_live{application="motd"}`
- **Logs**: Grafana → Explore → Loki → `{namespace="app-motd-dev"}`
- **Traces**: Grafana → Explore → Tempo → Search, service name `motd`

See [install-observability.md](install-observability.md#6-validate-telemetry) for the general pattern.

## Configuration Reference

### motd chart (`gitops-repo/charts/motd/values.yaml`)

| Key | Purpose |
|-----|---------|
| `image.repository` / `image.tag` | `ghcr.io/codesqueak/motd`; `tag` is overridden per-environment by CI, not edited by hand |
| `env` | Sets `SPRING_PROFILES_ACTIVE=prod` - `application-prod.properties` is layered over the base `application.properties` |
| `resources` | Environment-specific limits live in `environments/dev/motd-values.yaml`, merged over the chart defaults |
| `livenessProbe` / `readinessProbe` | Spring Boot Actuator's `/actuator/health/liveness` and `/actuator/health/readiness` groups |

### motd-ui chart (`gitops-repo/charts/motd-ui/values.yaml`)

| Key | Purpose |
|-----|---------|
| `motdBackend.host` / `.port` | Where nginx proxies `/api/` to - `motd-dev.app-motd-dev.svc.cluster.local:8000` |
| `motdBackend.resolver` | **Must be an IP, not a hostname.** nginx's `resolver` directive can't recursively resolve the resolver itself, so this is hardcoded to the cluster's kube-dns ClusterIP (`kubectl get svc -n kube-system kube-dns`). If kube-dns's ClusterIP ever changes (e.g. cluster rebuilt with a different service CIDR), this value needs updating. |
| `ingress.host` | `motd-ui.local` - add a matching `/etc/hosts` entry per step 3 above |
| `service.port` / `.targetPort` | nginx listens on 8080 inside the container (matches the Dockerfile's `EXPOSE 8080` and the unprivileged nginx image, which can't bind <1024) |

### Port allocation

Application services use the **8000-8099** block (see [port-usage.md](port-usage.md)) - `motd` is `8000`.
A new service should take the next free port in that range and update `port-usage.md` accordingly.

## Adding a new service (using motd as a template)

To replicate this pattern for a new Spring Boot or frontend service:

1. Create the app repo, copy `motd`'s or `motd-ui`'s `.github/workflows/build-publish.yml` as a starting
   point (adjust the build steps - Gradle/buildpacks vs. npm/docker - the GHCR push and gitops-tag-update
   steps stay the same shape).
2. Add a `GITOPS_PAT` repository secret to the new repo (same PAT already used by `motd`/`motd-ui`, or a
   new one with the same write access to `codesqueak/gitops`).
3. Add a Helm chart under `gitops-repo/charts/<service>/`, modelled on `charts/motd` (backend) or
   `charts/motd-ui` (frontend-with-nginx-proxy).
4. Add `gitops-repo/environments/dev/<service>-values.yaml` (just the fields CI needs to override, e.g.
   `image.tag`).
5. Add `gitops-repo/applications/dev/<service>.yaml`, modelled on `motd.yaml` - same `syncPolicy.automated`
   + `CreateNamespace=true` pattern.
6. Reserve the next port in the 8000-8099 block and update `port-usage.md`.
7. Push the app repo, then push the gitops repo - `root`'s `selfHeal` picks up the new Application
   automatically, no separate bootstrap step needed.

## Troubleshooting

**New image tag isn't showing up after a push**

ArgoCD's `motd-dev`/`motd-ui-dev` Applications poll git every ~3 minutes by default. To force it
immediately:

```bash
kubectl patch application motd-dev -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

First check that CI actually finished and pushed the tag commit:

```bash
gh run list --repo codesqueak/motd --limit 1
git -C gitops-repo log --oneline -1 -- environments/dev/motd-values.yaml
```

**`ImagePullBackOff` on motd-dev or motd-ui-dev**

Almost always means the GHCR package got flipped to private without a matching pull secret - see
[TODO.md](TODO.md) for how to create `ghcr-credentials`.

**motd-ui.local returns a 502 from nginx on `/api/*` calls, but static assets load fine**

The `resolver` IP in `motdBackend.resolver` no longer matches kube-dns's actual ClusterIP (this happens if
the cluster's service CIDR ever changes). Check with `kubectl get svc -n kube-system kube-dns` and update
`gitops-repo/charts/motd-ui/values.yaml` if it's drifted.

**404 / connection refused on `motd-ui.local`**

Check `/etc/hosts` has the entry, and that it points at ingress-nginx's actual LoadBalancer IP
(`kubectl get svc -n ingress-nginx ingress-nginx-controller`) - this can change if the cluster is
recreated, per the subnet-pinning note in [install-kubernetes.md](install-kubernetes.md).

## Debugging

```bash
# Application status
kubectl get application motd-dev motd-ui-dev -n argocd

# Pods / logs
kubectl get pods -n app-motd-dev
kubectl logs -n app-motd-dev deploy/motd-dev --tail=50
kubectl get pods -n app-motd-ui-dev
kubectl logs -n app-motd-ui-dev deploy/motd-ui-dev --tail=50

# What image/tag is actually running
kubectl get deploy -n app-motd-dev motd-dev -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get deploy -n app-motd-ui-dev motd-ui-dev -o jsonpath='{.spec.template.spec.containers[0].image}'

# ArgoCD CLI (see install-observability.md#debugging for login steps)
argocd app get motd-dev
argocd app sync motd-dev
```

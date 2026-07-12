# Component Versions

Quick reference for the Helm chart versions currently pinned in `gitops-repo/observability/apps/` and
`gitops-repo/infrastructure/apps/`. Chart versions are deliberately pinned rather than left to float to
`latest` (see [install-observability.md](install-observability.md#helm-chart-version-management)) - update
this table whenever a `targetRevision` is bumped so it stays a trustworthy source of "what's actually
running" without needing to grep every Application manifest.

| Component | Helm chart | Chart version | App version | Chart released | Helm repo |
|---|---|---|---|---|---|
| Alloy | `grafana/alloy` | 1.10.1 | v1.17.1 | 2026-06-30 | https://grafana.github.io/helm-charts |
| Grafana | `grafana/grafana` | 10.5.15 | 12.3.1 | 2026-01-30 | https://grafana.github.io/helm-charts |
| kube-state-metrics | `prometheus-community/kube-state-metrics` | 7.8.1 | 2.19.1 | 2026-07-11 | https://prometheus-community.github.io/helm-charts |
| Loki | `grafana/loki` | 7.0.0 | 3.6.7 | 2026-04-23 | https://grafana.github.io/helm-charts |
| Mimir | `grafana/mimir-distributed` | 6.1.0 | 3.1.2 | 2026-06-29 | https://grafana.github.io/helm-charts |
| prometheus-node-exporter | `prometheus-community/prometheus-node-exporter` | 4.56.0 | 1.12.0 | 2026-07-11 | https://prometheus-community.github.io/helm-charts |
| SeaweedFS | `seaweedfs/seaweedfs` | 4.39.0 | 4.39 | 2026-07-10 | https://seaweedfs.github.io/seaweedfs/helm |
| Tempo | `grafana/tempo-distributed` | 1.61.3 | 2.9.0 | 2026-01-30 | https://grafana.github.io/helm-charts |
| MetalLB | `metallb/metallb` | 0.16.1 | v0.16.1 | 2026-05-27 | https://metallb.github.io/metallb |
| ingress-nginx | `ingress-nginx/ingress-nginx` | 4.15.1 | 1.15.1 | 2026-03-19 | https://kubernetes.github.io/ingress-nginx |

## Notes

- **MetalLB 0.16.x** made FRR-K8s the default BGP backend, deprecating classic FRR. This cluster only uses
  `IPAddressPool`/`L2Advertisement` (`gitops-repo/infrastructure/metallb/config/dev/pools.yaml`), never BGP,
  so the change has no effect here - worth revisiting if BGP mode is ever adopted.
- **Mimir 6.1.0** raises the minimum supported Kubernetes version to 1.32. This cluster runs 1.36.1.
- Check for newer versions with `helm search repo <repo>/<chart> --versions` (after `helm repo add`/`update`),
  or query the repo's `index.yaml` directly for exact release dates, e.g.:
  ```bash
  curl -s https://grafana.github.io/helm-charts/index.yaml | yq '.entries.alloy[0]'
  ```
- Always dry-run a template render before bumping a pinned version - see
  [install-observability.md](install-observability.md#helm-chart-version-management) for the process.

Last updated: 2026-07-12

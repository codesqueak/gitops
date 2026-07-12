# A Practical Demonstration of Developing Against a Kubernetes Environment

This project was developed as a side project to something else I was building (The Panopticon - the main project on this GitHub site).
I found that setting up a production-like environment was considerably more difficult than it initially appeared from the relevant documentation.

After going through considerable effort to get an environment working, I decided to document it, as having a fully constructed working example
is amazingly useful when trying to attempt something. Hopefully others who tread this path after me will find this guide useful. 

Consider this a glorified Hello World!

## 1. What I wanted

A highly automated environment where I could commit code as a developer, which would then go through the build / test / deploy cycle with minimal intervention into
a production-like environment

This environment needed to have the following characteristics

1. Everything built as Docker containers and deployed into a Kubernetes environment
2. Complete automation from the point of the git commit
3. Full observability stack
4. Running a local environment that mimicked a real-world, cloud-based environment as closely as possible

## 2. The Parts

The project is split into three distinct areas:

1. Getting Kubernetes up and running, with associated tooling — see [install-kubernetes.md](install-kubernetes.md)
2. Deployment of an observability environment in Kubernetes — see [install-observability.md](install-observability.md)
3. Deployment of the application services — see [install-motd.md](install-motd.md)

## 3. Technology

### Kubernetes

[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=flat&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white)](https://www.docker.com/)
[![Helm](https://img.shields.io/badge/Helm-0F1689?style=flat&logo=helm&logoColor=white)](https://helm.sh/)
[![Kind](https://img.shields.io/badge/Kind-326CE5?style=flat&logo=kubernetes&logoColor=white)](https://kind.sigs.k8s.io/)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-EF7B4D?style=flat&logo=argo&logoColor=white)](https://argo-cd.readthedocs.io/)
[![kubectl](https://img.shields.io/badge/kubectl-326CE5?style=flat&logo=kubernetes&logoColor=white)](https://kubernetes.io/docs/reference/kubectl/)
[![GitHub](https://img.shields.io/badge/GitHub-181717?style=flat&logo=github&logoColor=white)](https://github.com/)

1. Everything is hosted on an Ubuntu Linux installation
2. A GitHub account to keep the gitops project / automation etc
3. Locally installed applications
   - [Docker](https://www.docker.com/)
   - [Helm](https://helm.sh/)
   - [Kind](https://kind.sigs.k8s.io/) implementation of Kubernetes
   - [ArgoCD](https://argo-cd.readthedocs.io/)
   - [Kubectl](https://kubernetes.io/docs/reference/kubectl/)

### Observability

[![SeaweedFS](https://img.shields.io/badge/SeaweedFS-2E8B57?style=flat&logo=apache&logoColor=white)](https://github.com/seaweedfs/seaweedfs)
[![Mimir](https://img.shields.io/badge/Mimir-F9AE41?style=flat&logo=grafana&logoColor=white)](https://grafana.com/oss/mimir/)
[![Loki](https://img.shields.io/badge/Loki-F5A623?style=flat&logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![Tempo](https://img.shields.io/badge/Tempo-6E4FF6?style=flat&logo=grafana&logoColor=white)](https://grafana.com/oss/tempo/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=flat&logo=grafana&logoColor=white)](https://grafana.com/oss/grafana/)
[![kube-state-metrics](https://img.shields.io/badge/kube--state--metrics-326CE5?style=flat&logo=kubernetes&logoColor=white)](https://github.com/kubernetes/kube-state-metrics)
[![node-exporter](https://img.shields.io/badge/node--exporter-E6522C?style=flat&logo=prometheus&logoColor=white)](https://github.com/prometheus/node_exporter)
[![Alloy](https://img.shields.io/badge/Alloy-FF7B00?style=flat&logo=grafana&logoColor=white)](https://grafana.com/docs/alloy/latest/)

#### Data flow

![Observability data flow: application pods and cluster exporters feed into Alloy, which forwards metrics to Mimir, logs to Loki and traces to Tempo; each backend writes to SeaweedFS for storage and is queried by Grafana](docs/observability-flow.svg)

- 🟧 Metrics &nbsp;·&nbsp; 🟩 Logs &nbsp;·&nbsp; 🟪 Traces &nbsp;·&nbsp; 🟦 Multi-signal / infra
- Solid arrows: ingest / write path &nbsp;·&nbsp; Dashed arrows: query / read path

| Component | Responsibilities |
|-----------|-------------------|
| [SeaweedFS](https://github.com/seaweedfs/seaweedfs) | S3-compatible object storage backend for Mimir, Loki and Tempo — same API as AWS S3 so backend config is identical between dev and prod |
| [Mimir](https://grafana.com/oss/mimir/) | Metric storage, long-term retention, PromQL query support |
| [Loki](https://grafana.com/oss/loki/) | Log storage, LogQL queries, Kubernetes log aggregation |
| [Tempo](https://grafana.com/oss/tempo/) | Distributed trace storage, trace search, service dependency analysis |
| [Grafana](https://grafana.com/oss/grafana/) | Dashboards, alerting, metrics/logs/traces exploration; data sources for Mimir, Loki, Tempo |
| [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics) | Deployment status, replica counts, pod state, job state, HPA metrics |
| [prometheus-node-exporter](https://github.com/prometheus/node_exporter) | CPU, memory, disk, network metrics |
| [Alloy](https://grafana.com/docs/alloy/latest/) | OTLP ingestion, log collection, metric scraping, forwarding to Mimir, Loki and Tempo |

### Application

[![Java](https://img.shields.io/badge/Java-ED8B00?style=flat&logo=openjdk&logoColor=white)](https://www.java.com/)
[![Spring Boot](https://img.shields.io/badge/SpringBoot-6DB33F?style=flat&logo=springboot&logoColor=white)](https://spring.io/projects/spring-boot)
[![React](https://img.shields.io/badge/React-20232A?style=flat&logo=react&logoColor=61DAFB)](https://react.dev/)

1. A [Message of the Day server](https://github.com/codesqueak/motd) - Java / Spring Boot 4
2. A [UI to present messages](https://github.com/codesqueak/motd-ui) - React




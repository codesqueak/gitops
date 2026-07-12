# Kind Single-Node Kubernetes Setup on Ubuntu

This guide installs:

* Docker Engine (official Docker packages)
* Docker Compose v2
* kubectl
* Kind (Kubernetes in Docker)
* Helm
* A single-node control-plane + worker Kubernetes cluster for local development and testing
* ArgoCD

This setup provides a lightweight local Kubernetes environment using upstream Kubernetes components and is suitable for application development, Helm testing, CI/CD validation, and Kubernetes learning. It is also the foundation the [install-observability.md](install-observability.md) guide builds on — follow this document first, then move on to that one.

---

# Prerequisites

* Ubuntu 22.04 LTS or newer
* Internet access
* User with sudo privileges

---

# 1. Install Docker Engine and Docker Compose

## Remove Old Docker Packages (Optional)

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg
done
```

## Configure Docker's Official Repository

Update package lists and install prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
```

Create the keyring directory:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
```

Download Docker's GPG key:

```bash
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
```

Set permissions:

```bash
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

Add Docker's repository:

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Update package indexes:

```bash
sudo apt-get update
```

## Install Docker

```bash
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

## Verify Docker Installation

```bash
docker --version
```

Expected output:

```text
Docker version xx.x.x
```

Test Docker:

```bash
sudo docker run hello-world
```

## Enable Docker for Non-Root Users

```bash
sudo usermod -aG docker $USER
```

Apply the group membership immediately:

```bash
newgrp docker
```

Verify:

```bash
docker run hello-world
```

---

# 2. Verify Docker Compose

Docker Compose v2 is installed as a Docker plugin.

Check the version:

```bash
docker compose version
```

Expected output:

```text
Docker Compose version v2.x.x
```

## Test Docker Compose

Create a test directory:

```bash
mkdir ~/compose-test
cd ~/compose-test
```

Create a file named `compose.yaml`:

```yaml
services:
  nginx:
    image: nginx:latest
    ports:
      - "8080:80"
```

Start the container:

```bash
docker compose up -d
```

Verify:

```bash
docker compose ps
```

Open:

```text
http://localhost:8080
```

You should see the NGINX welcome page.

Stop and remove the container:

```bash
docker compose down
```

---

# 3. Install kubectl

Download the latest stable version:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
```

Install:

```bash
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

Verify:

```bash
kubectl version --client
```

Expected output:

```text
Client Version: v1.xx.x
```

---

# 4. Install Kind

Download Kind:

```bash
curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
```

Install:

```bash
chmod +x kind
sudo mv kind /usr/local/bin/
```

Verify:

```bash
kind version
```

Expected output:

```text
kind version x.x.x
```

---

# 5. Install Helm

Helm is the package manager for Kubernetes and is commonly used to deploy applications, ingress controllers, monitoring stacks, databases, and other services.

Download and run the official installation script:

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4

chmod 700 get_helm.sh

./get_helm.sh
```

Verify:

```bash
helm version
```

Expected output:

```text
version.BuildInfo{
  Version:"v4.x.x",
  ...
}
```

---

# 6. Host inotify limits

kind nodes are containers sharing the host kernel's inotify accounting — it is not namespaced per-container. The observability stack deployed on top of this cluster (Loki, Mimir, Tempo, Alloy, Grafana) runs enough pods with fsnotify-based config/cert watchers to exceed the Linux default `fs.inotify.max_user_instances` (128) quickly; on this cluster usage reached ~1823 instances.

Once exhausted, the failure is **not confined to observability pods**. `kube-proxy` on the affected node crashes with `too many open files`, which breaks Service/ClusterIP and DNS routing for every other pod on that node — so ArgoCD, ingress-nginx, MetalLB, and any observability component scheduled there will crash-loop too, each with a different-looking symptom.

Apply this **before creating the cluster** — raise the limit on the actual Docker/kind host (must be run on the host, not via `docker exec` into a node — the setting is shared, but only persists if applied at the host level):

```bash
sudo tee /etc/sysctl.d/99-kind-inotify.conf <<'CONF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
CONF
sudo sysctl --system
```

---

# 7. Create a Kubernetes Cluster with Control Plane and Worker Node

## Pin the Docker network subnet

`kind create cluster` auto-creates a Docker network named `kind` on first run, and Docker's default address-pool allocator picks whatever subnet is next available — this is not guaranteed to be the same subnet from one host (or one network teardown) to the next.

The observability stack's MetalLB `IPAddressPool` is statically configured for `172.20.255.200-172.20.255.250` (see `gitops-repo/infrastructure/metallb/config/dev/pools.yaml`), and [install-observability.md](install-observability.md) expects ingress-nginx to land on `172.20.255.200`. For that pool to be reachable, the `kind` Docker network must be on the `172.20.0.0/16` subnet. Pin it explicitly before creating the cluster, rather than relying on Docker to happen to allocate it:

```bash
docker network inspect kind >/dev/null 2>&1 || \
  docker network create kind --subnet 172.20.0.0/16 --gateway 172.20.0.1
```

If a `kind` network already exists on a different subnet, remove it first (this fails if a cluster is currently using it — delete the cluster first with `kind delete cluster --name dev`):

```bash
docker network rm kind
```

## Create the cluster

Create a cluster file, kind-dev.yaml:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  - role: control-plane
  - role: worker
```

Create the nodes:

```bash
kind create cluster --name dev --config kind-dev.yaml
```

Verify cluster creation:

```bash
kubectl cluster-info
```

List nodes:

```bash
kubectl get nodes
```

Expected output:

```text
NAME                STATUS   ROLES           AGE
dev-control-plane   Ready    control-plane   1m
dev-worker          Ready    <none>          1m
```

## Verify Cluster Health

Check all system pods:

```bash
kubectl get pods -A
```

You should see pods in namespaces such as:

```text
kube-system
local-path-storage
```

All pods should eventually reach the `Running` state.

---

# 8. Install ArgoCD

## Create installation directory

```bash
mkdir -p argocd-install
cd argocd-install
```

## Configuration File

Create a file called kustomization.yaml:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
- https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## Deploy ArgoCD

```bash
kubectl create namespace argocd

kubectl apply --server-side --force-conflicts -k .

kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
kubectl wait --for=condition=available --timeout=600s deployment/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s

kubectl get pods -n argocd

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

kubectl port-forward svc/argocd-server -n argocd 8080:443
```

> `argocd-application-controller` is a `StatefulSet`, not a `Deployment` — `kubectl wait --for=condition=available` only applies to Deployments, so it must be checked with `kubectl rollout status` instead.

We should now be able to login using admin / \<password from last command\>

Location: https://localhost:8080

Reset the password!

## Install the ArgoCD CLI

Download the CLI:

```bash
curl -sSL -o argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
```

Install:

```bash
chmod +x argocd

sudo mv argocd /usr/local/bin/
```

Verify:

```bash
argocd version --client
```

## Log In Using the CLI

In a separate terminal:

```bash
argocd login localhost:8080 \
  --username admin \
  --password <password> \
  --insecure
```

Verify:

```bash
argocd account get-user-info
```

---

# Recommended Repository Structure

For GitOps with GitHub and GHCR:

```text
github.com/myorg/myapp
├── application source
├── Dockerfile
└── GitHub Actions

github.com/myorg/gitops
└── environments
    ├── dev
    ├── test
    └── prod
```

The application repository:

1. Builds containers.
2. Pushes images to GHCR.
3. Updates Helm values or manifests in the GitOps repository.

Argo CD watches the GitOps repository and deploys changes automatically.

---

# Common Argo CD Commands

List applications:

```bash
argocd app list
```

Get application details:

```bash
argocd app get <app-name>
```

Synchronize an application:

```bash
argocd app sync <app-name>
```

Refresh application status:

```bash
argocd app refresh <app-name>
```

Delete an application:

```bash
argocd app delete <app-name>
```

---

# Uninstall Argo CD

ArgoCD was installed above via `kubectl apply -k` against the raw upstream manifest (not Helm), so it must be removed the same way:

```bash
kubectl delete -k argocd-install/
```

Or, more simply, delete the whole namespace:

```bash
kubectl delete namespace argocd
```

---

# Useful Kubernetes Commands

Current context:

```bash
kubectl config current-context
```

List nodes:

```bash
kubectl get nodes
```

List all pods:

```bash
kubectl get pods -A
```

Describe a pod:

```bash
kubectl describe pod <pod-name>
```

View logs:

```bash
kubectl logs <pod-name>
```

List services:

```bash
kubectl get svc
```

List deployments:

```bash
kubectl get deployments
```

---

# Useful Kind Commands

List clusters:

```bash
kind get clusters
```

Export cluster kubeconfig:

```bash
kind export kubeconfig --name dev
```

Delete the cluster:

```bash
kind delete cluster --name dev
```

Recreate the cluster:

```bash
kind create cluster \
  --name dev \
  --image kindest/node:v1.33.1
```

---

# Common Docker Compose Commands

Start services:

```bash
docker compose up -d
```

View running services:

```bash
docker compose ps
```

View logs:

```bash
docker compose logs -f
```

Restart services:

```bash
docker compose restart
```

Stop services:

```bash
docker compose stop
```

Remove services and networks:

```bash
docker compose down
```

---

# Cleanup

Delete the Kubernetes cluster:

```bash
kind delete cluster --name dev
```

Remove test Compose files:

```bash
rm -rf ~/compose-test
```

---

# Next Steps

The cluster and ArgoCD created above are the prerequisites for [install-observability.md](install-observability.md), which deploys the rest of the stack — MetalLB, ingress-nginx, SeaweedFS, Mimir, Loki, Tempo, Grafana, Alloy, kube-state-metrics and node-exporter — automatically via ArgoCD's app-of-apps pattern. There is no need to install MetalLB, ingress-nginx, or cert-manager by hand; they are managed by the `infrastructure` app defined in `gitops-repo/applications/dev` once the root app is bootstrapped.

Continue with [install-observability.md](install-observability.md).

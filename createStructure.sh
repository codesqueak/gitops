# Create repo root
mkdir -p gitops
cd gitops || exit

# Bootstrap
mkdir -p bootstrap

# Argo CD applications
mkdir -p applications/{dev,test,prod}

# Helm charts (one per service)
mkdir -p charts/{panui,panbff,panuser,pansensor,pancapture,panuser,panlist}

# Standard Helm chart structure
for svc in panui panbff panuser pansensor pancapture panuser panlist; do
  mkdir -p charts/$svc/templates
  touch charts/$svc/Chart.yaml
  touch charts/$svc/values.yaml
done

# Environment-specific values
mkdir -p environments/{dev,test,prod}

for env in dev test prod; do
  touch environments/$env/frontend-values.yaml
  touch environments/$env/api-values.yaml
  touch environments/$env/auth-values.yaml
  touch environments/$env/worker-values.yaml
  touch environments/$env/scheduler-values.yaml
done

# Argo CD application definitions
for env in dev test prod; do
  touch applications/$env/frontend.yaml
  touch applications/$env/api.yaml
  touch applications/$env/auth.yaml
  touch applications/$env/worker.yaml
  touch applications/$env/scheduler.yaml
done

# Bootstrap manifests
touch bootstrap/root-app.yaml
touch bootstrap/projects.yaml

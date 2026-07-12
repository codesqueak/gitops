# TODO

- **Create a real `ghcr-credentials` pull secret** if `ghcr.io/codesqueak/motd` or
  `ghcr.io/codesqueak/motd-ui` are ever flipped back to private visibility. Both
  charts already reference `imagePullSecrets: ghcr-credentials`
  (`gitops-repo/charts/motd/values.yaml`, `gitops-repo/charts/motd-ui/values.yaml`),
  but the secret doesn't currently exist in either namespace - it's a no-op
  reference while the GHCR packages are public.

  To add it:
  1. Generate a GitHub PAT (classic or fine-grained) with `read:packages` scope
     for the `codesqueak` org.
  2. Create the secret in both app namespaces:
     ```bash
     kubectl create secret docker-registry ghcr-credentials \
       --docker-server=ghcr.io \
       --docker-username=<github-username> \
       --docker-password=<PAT> \
       -n app-motd-dev

     kubectl create secret docker-registry ghcr-credentials \
       --docker-server=ghcr.io \
       --docker-username=<github-username> \
       --docker-password=<PAT> \
       -n app-motd-ui-dev
     ```
  3. No chart/values changes needed - `imagePullSecrets` is already wired up.

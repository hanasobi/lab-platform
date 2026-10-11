# Bootstrap

One-time steps to bring up the platform on a fresh cluster.

Prerequisite: node prepared, `kubeadm init` done, no CNI installed yet.
Run all commands from the repository root on the control plane node.

Status: each step was run on node-01, but a full rebuild from scratch
has not been tested end to end.

## 1. Gateway API CRDs

Cilium requires them before Gateway API is enabled.

    kubectl apply --server-side -f components/gateway-api-crds/standard-install.yaml

## 2. Cilium

    helm repo add cilium https://helm.cilium.io
    helm install cilium cilium/cilium --version 1.19.4 \
      -n kube-system -f components/cilium/values.yaml
    kubectl -n kube-system rollout status ds/cilium

The Cilium Helm release is not managed by Argo CD. Upgrade it with
`helm upgrade` and the same values file.

## 3. Argo CD

    helm repo add argo https://argoproj.github.io/argo-helm
    helm install argocd argo/argo-cd --version 10.10.2 \
      -n argocd --create-namespace \
      -f components/argocd/values.yaml --wait --timeout 10m

Use the chart version from `apps/argocd.yaml`. The release name must be
`argocd`.

## 4. Root application

    kubectl apply -f bootstrap/root.yaml

From here on Argo CD installs everything under `apps/` and manages itself.
Do not use `helm upgrade` for Argo CD after this step.

## After the bootstrap

- Initial admin password:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- Change it in the UI, then delete the secret.

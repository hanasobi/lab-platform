# lab-platform

Platform foundation of a small on-prem Kubernetes cluster for AI workloads,
managed with Argo CD.

- `bootstrap/`  the steps from an empty machine to the running platform,
  kubeadm configuration, root Application
- `ansible/`    playbook that prepares a node for kubeadm
- `apps/`       one Argo CD Application per component
- `components/` Helm values and manifests per component

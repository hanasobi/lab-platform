# lab-platform

Platform foundation of a small on-prem Kubernetes cluster for AI workloads,
managed with Argo CD.

- `bootstrap/`  one-time steps to bring up a cluster, root Application
- `apps/`       one Argo CD Application per component
- `components/` Helm values and manifests per component

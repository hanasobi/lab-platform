#!/usr/bin/env bash
# Entfernt beendete Pods von Deployments, StatefulSets und DaemonSets.
# Pods von Jobs und Argo Workflows bleiben unangetastet.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

for i in $(seq 1 30); do
  kubectl get --raw /readyz >/dev/null 2>&1 && break
  if [ "$i" -eq 30 ]; then echo "API-Server nicht erreichbar" >&2; exit 1; fi
  sleep 10
done

kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind' \
| awk '($3=="Succeeded" || $3=="Failed") && ($4=="ReplicaSet" || $4=="StatefulSet" || $4=="DaemonSet") {print $1, $2}' \
| while read -r ns name; do
    kubectl delete pod -n "$ns" "$name"
  done

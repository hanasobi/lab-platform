#!/usr/bin/env bash
#
# teardown-node.sh
#
# Removes the Kubernetes cluster from this node together with everything
# that ansible/node.yaml installed. Afterwards the node is where
# bootstrap/README.md, section 3 ("Node setup") starts.
#
# DESTRUCTIVE. The cluster, etcd, all certificates and all container images
# are gone afterwards. There is no way back except a new bootstrap.
#
# Removed:
#   - the cluster (kubeadm reset), /etc/kubernetes, /var/lib/kubelet
#   - kubelet, kubeadm, kubectl, containerd and their configuration
#   - the contents of the volumes /var/lib/etcd and /var/lib/containerd
#   - helm, cilium, etcdctl, etcdutl in /usr/local/bin
#   - the snapshot, cleanup and power-off scripts with their systemd units
#   - kernel module, sysctl and logind settings written by the playbook
#
# Kept:
#   - operating system, network configuration, SSH access, base packages
#   - the logical volumes and their fstab entries
#   - /var/lib/local-path-provisioner (data of persistent volumes)
#   - old etcd snapshots, moved to /var/backups/etcd.before-teardown-<time>
#   - home directories, including the working copy of this repository
#
# Two phases, on purpose:
#   1. This script. It does not touch any network interface.
#   2. A reboot, started by hand. Only the reboot removes the Cilium
#      interfaces and eBPF programs.
# With kube-proxy replacement and WireGuard, Cilium attaches eBPF programs to
# the physical network card. Deleting the Cilium interfaces on a running node
# cut the SSH session and the whole network of this headless machine in
# July 2026. Recovery needed a power cycle. Never add "ip link delete" here.
#
# Usage:
#   sudo ./bootstrap/teardown-node.sh          asks for confirmation
#   sudo ./bootstrap/teardown-node.sh --yes    no question

set -uo pipefail   # no -e: every step has to run, whatever the node looks like

log()  { printf "\033[1;32m[%(%H:%M:%S)T]\033[0m %s\n" -1 "$*"; }
warn() { printf "\033[1;33m[%(%H:%M:%S)T] WARN:\033[0m %s\n" -1 "$*" >&2; }
die()  { printf "\033[1;31m[%(%H:%M:%S)T] ERROR:\033[0m %s\n" -1 "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script with sudo."

PV_DIR=/var/lib/local-path-provisioner
SNAPSHOT_DIR=/var/backups/etcd

# ----------------------------------------------------------------------------
# Confirmation
# ----------------------------------------------------------------------------

if [[ "${1:-}" != "--yes" ]]; then
  echo ""
  warn "This removes the Kubernetes cluster on $(hostname) for good:"
  warn "  cluster, etcd, certificates, container images, node tooling."
  if [[ -d "$PV_DIR" && -n "$(ls -A "$PV_DIR" 2>/dev/null)" ]]; then
    warn ""
    warn "  $PV_DIR is not empty. The data stays on disk,"
    warn "  but the new cluster will not know these volumes."
  fi
  echo ""
  read -r -p "Type the host name ($(hostname)) to continue: " answer
  [[ "$answer" == "$(hostname)" ]] || die "Aborted."
fi

# Empties a directory but keeps the directory itself. Needed for mount
# points: the volume stays mounted, only its contents go.
empty_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -xdev -delete \
    && log "  $dir emptied" \
    || warn "  could not empty $dir completely"
}

# ----------------------------------------------------------------------------
# 1. Timers. Without a cluster both services would only wait and fail.
# ----------------------------------------------------------------------------

log "[1/7] Stopping timers..."
systemctl disable --now etcd-snapshot.timer k8s-prune-terminated.timer >/dev/null 2>&1 \
  && log "  timers stopped and disabled" \
  || log "  timers not present or already stopped"

# ----------------------------------------------------------------------------
# 2. kubeadm reset. First, while containerd still runs, so that kubeadm can
#    stop the containers and unmount what the kubelet mounted.
# ----------------------------------------------------------------------------

log "[2/7] kubeadm reset..."
if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset --force || warn "  kubeadm reset reported an error, continuing"
else
  log "  kubeadm not installed, skipped"
fi

# ----------------------------------------------------------------------------
# 3. Packages
# ----------------------------------------------------------------------------

log "[3/7] Removing packages..."
export DEBIAN_FRONTEND=noninteractive
# Release all holds first. kubeadm depends on kubelet, and apt refuses to
# remove a package while a held one still depends on it.
for pkg in kubelet kubeadm kubectl containerd; do
  apt-mark unhold "$pkg" >/dev/null 2>&1 || true
done
for pkg in kubelet kubeadm kubectl containerd; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-get purge -y -qq "$pkg" >/dev/null \
      && log "  $pkg purged" \
      || warn "  could not purge $pkg"
  else
    log "  $pkg not installed, skipped"
  fi
done
apt-get autoremove -y -qq >/dev/null || true

# ----------------------------------------------------------------------------
# 4. Files written by the playbook
# ----------------------------------------------------------------------------

log "[4/7] Removing node configuration and tooling..."
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/99-kubernetes.conf
rm -rf /etc/containerd
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/systemd/logind.conf.d/zz-kubelet-shutdown.conf
rm -f /usr/local/sbin/etcd-snapshot.sh \
      /usr/local/sbin/k8s-prune-terminated.sh \
      /usr/local/sbin/node-off
rm -f /etc/systemd/system/etcd-snapshot.service \
      /etc/systemd/system/etcd-snapshot.timer \
      /etc/systemd/system/k8s-prune-terminated.service \
      /etc/systemd/system/k8s-prune-terminated.timer
rm -f /usr/local/bin/helm /usr/local/bin/cilium \
      /usr/local/bin/etcdctl /usr/local/bin/etcdutl
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl kill -s HUP systemd-logind >/dev/null 2>&1 || true
log "  done"

# ----------------------------------------------------------------------------
# 5. Cluster state. /etc/cni/net.d holds plain configuration files, removing
#    them does not touch an interface.
# ----------------------------------------------------------------------------

log "[5/7] Removing cluster state..."
rm -rf /etc/kubernetes
rm -rf --one-file-system /var/lib/kubelet \
  || warn "  /var/lib/kubelet not removed completely, the reboot releases the rest"
rm -rf /etc/cni/net.d/* /var/run/cilium /var/lib/cilium
empty_dir /var/lib/etcd
empty_dir /var/lib/containerd

target_user="${SUDO_USER:-}"
if [[ -n "$target_user" ]]; then
  target_home=$(getent passwd "$target_user" | cut -d: -f6)
  if [[ -n "$target_home" && -f "$target_home/.kube/config" ]]; then
    rm -f "$target_home/.kube/config" && log "  kubeconfig of $target_user removed"
  fi
fi

# ----------------------------------------------------------------------------
# 6. Old snapshots. They belong to the old cluster and its certificates and
#    must not mix with snapshots of the new one.
# ----------------------------------------------------------------------------

log "[6/7] Moving old etcd snapshots aside..."
if [[ -d "$SNAPSHOT_DIR" && -n "$(ls -A "$SNAPSHOT_DIR" 2>/dev/null)" ]]; then
  aside="${SNAPSHOT_DIR}.before-teardown-$(date +%Y%m%d-%H%M%S)"
  mv "$SNAPSHOT_DIR" "$aside" && log "  moved to $aside"
else
  log "  none found"
fi

# ----------------------------------------------------------------------------
# 7. Verification
# ----------------------------------------------------------------------------

log "[7/7] Verification..."
echo ""
echo "--- Packages (expected: none) ---"
dpkg -l 2>/dev/null | grep -E '^(ii|hi)\s+(containerd|kubelet|kubeadm|kubectl)\s' \
  && warn "  packages above are still installed" \
  || echo "  none"

echo ""
echo "--- Volumes (expected: mounted and empty) ---"
for dir in /var/lib/etcd /var/lib/containerd; do
  if findmnt "$dir" >/dev/null 2>&1; then
    echo "  $dir: mounted, $(find "$dir" -mindepth 1 -maxdepth 1 | wc -l) entries"
  else
    echo "  $dir: not a mount point"
  fi
done
if [[ -d "$PV_DIR" ]]; then
  echo "  $PV_DIR: kept, $(find "$PV_DIR" -mindepth 1 -maxdepth 1 | wc -l) entries"
fi

echo ""
echo "--- Cilium interfaces (expected until the reboot) ---"
ip -o link show 2>/dev/null | grep -E 'cilium|lxc' | awk -F': ' '{print "  " $2}' \
  || echo "  none"

cat <<'EOF'

===== Phase 1 done =====

Phase 2 is a reboot, started by hand:

    sudo reboot

"sudo node-off" no longer exists. The reboot removes the Cilium interfaces
and eBPF programs. Netplan brings the network card back up.

After the reboot continue with bootstrap/README.md, section 3.

EOF

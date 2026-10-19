# Node setup

`node.yaml` prepares a freshly installed Ubuntu Server 24.04 node for
kubeadm. It runs on the node it configures, there is no control machine.
Where it fits in: `bootstrap/README.md`, section 3.

    ansible-playbook node.yaml -K                  # apply
    ansible-playbook node.yaml -K --check --diff   # show changes only
    ansible-playbook node.yaml -K --tags storage   # one part

| Part (tag) | Nodes | Content |
|---|---|---|
| `base` | all | packages, time zone, swap off, kernel modules, sysctl |
| `storage` | all | logical volumes for containerd and persistent volumes, on the control plane also for etcd |
| `containerd` | all | containerd with the systemd cgroup driver, on hold |
| `kubernetes` | all | kubelet, kubeadm, kubectl, on hold |
| `shutdown` | all | shutdown delay in systemd-logind |
| `tools` | control plane | helm, cilium |
| `control-plane` | control plane | etcdctl, etcdutl, etcd snapshots, pod cleanup, `node-off` |

- `vars/common.yaml`: versions and volume sizes for all nodes.
- `vars/<hostname>.yaml`: one file per node. Without it the playbook stops.
- `files/`: scripts and systemd units, copied as they are.

The playbook does not run `kubeadm init`, `kubeadm join` or
`kubeadm upgrade`. Versions in `vars/common.yaml` describe a new node. On an
existing node the packages are on hold, and a different version makes the
run fail instead of upgrading.

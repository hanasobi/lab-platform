# Bootstrap

From an empty machine to the running platform, in the order of this file.
Every section ends with checks. Do not continue while a check fails.

| Section | What | How | Where |
|---|---|---|---|
| 1 | Operating system | by hand | console |
| 2 | Access and network | by hand | console, then SSH |
| 3 | Node setup | Ansible | SSH on the node |
| 4 | Cluster | `kubeadm init` | SSH on the node |
| 5 | Network | `kubectl`, `helm` | SSH on the node |
| 6 | Argo CD | `helm`, `kubectl` | SSH on the node |
| 7 | After the bootstrap | by hand | SSH on the node |

Sections 1 to 3 apply to every node. Sections 4 to 7 run once per cluster,
on the first control plane node. Joining further nodes and upgrades are not
part of this file yet.

Status: sections 3 to 7 have not been run in one go on an empty node yet.
Sections 1 and 2 describe how node-01 was installed in July 2026.

Values used below (node-01):

| | |
|---|---|
| Host name, also the Kubernetes node name | `node-01` |
| Address | `192.168.1.51/24`, gateway and DNS `192.168.1.1` |
| LAN interface | `enp9s0` |
| Volume group | `ubuntu-vg` |

## 1. Operating system

Ubuntu Server 24.04 LTS from a USB stick. In the installer:

- Network: leave on DHCP. The fixed address follows in section 2.
- Storage: "Use an entire disk", LVM on, encryption off. Leave the root
  volume at the proposed size of about 100 GB. The rest of the volume group
  must stay free, section 3 creates the other volumes from it.
- Server name: the host name from the table above. It becomes the name of
  the Kubernetes node and cannot be changed later without effort.
- Install the OpenSSH server.
- Do not select any snaps.

Checks after the first boot:

    hostnamectl --static        # node-01
    sudo vgs                    # ubuntu-vg with about 1.7 TB free

## 2. Access and network

SSH key from the workstation, then switch off password logins on the node:

    ssh-copy-id <user>@<current address>

    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo systemctl restart ssh

Fixed address. Create `/etc/netplan/60-static.yaml`:

    network:
      version: 2
      renderer: networkd
      ethernets:
        enp9s0:
          dhcp4: false
          dhcp6: false
          addresses:
            - 192.168.1.51/24
          routes:
            - to: default
              via: 192.168.1.1
          nameservers:
            addresses:
              - 192.168.1.1

Disable the file of the installer (`50-cloud-init.yaml` or
`00-installer-config.yaml`, see `ls /etc/netplan`), keep cloud-init from
writing it again, then apply:

    sudo chmod 600 /etc/netplan/60-static.yaml
    sudo mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.disabled
    echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    sudo netplan try

`netplan try` rolls back after 120 seconds unless confirmed with Enter. Over
SSH the session dies when the address changes: open a second session on the
new address, then confirm in the first one. At the console `sudo netplan
apply` is simpler.

Bring the system up to date. Reboot if a new kernel was installed:

    sudo apt-get update && sudo apt-get upgrade -y
    ls /var/run/reboot-required 2>/dev/null && sudo reboot

Checks:

    ip -4 -o addr show scope global     # 192.168.1.51 on enp9s0
    ip route show default               # via 192.168.1.1
    ping -c 2 archive.ubuntu.com
    sudo sshd -T | grep -i '^passwordauthentication'    # no

## 3. Node setup

The playbook runs on the node itself. It needs a file
`ansible/vars/<hostname>.yaml`. For a new node copy `vars/node-01.yaml`,
adjust it and commit it first.

    sudo apt-get install -y git ansible
    git clone https://github.com/hanasobi/lab-platform.git ~/lab-platform
    cd ~/lab-platform/ansible
    ansible-playbook node.yaml -K

`-K` asks for the sudo password. The playbook creates and mounts the
volumes, switches off swap, installs containerd and the Kubernetes packages
in the versions from `vars/common.yaml` and puts them on hold. On a control
plane node it also installs helm, cilium, etcdctl and etcdutl and the
scripts for etcd snapshots, pod cleanup and power-off.

To see what a run would change without changing anything:

    ansible-playbook node.yaml -K --check --diff

Checks:

    swapon --show                       # no output
    df -h /var/lib/containerd /var/lib/local-path-provisioner /var/lib/etcd
    sudo ls -A /var/lib/etcd            # no output, kubeadm needs it empty
    apt-mark showhold                   # containerd kubeadm kubectl kubelet
    containerd --version && kubeadm version -o short
    busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager InhibitDelayMaxUSec    # t 120000000
    helm version --short && cilium version --client | head -1 && etcdctl version | head -1

Each of the three paths in the `df` output must be a file system of its own
and not `/`.

On a fresh installation reboot once and repeat the first two checks. That
proves the entries in `/etc/fstab`. Until section 4 the kubelet restarts in
a loop, which is expected.

## 4. Cluster

Check the addresses and the version in `bootstrap/kubeadm-config.yaml`,
then:

    cd ~/lab-platform
    sudo kubeadm init --config bootstrap/kubeadm-config.yaml

    mkdir -p ~/.kube
    sudo cp /etc/kubernetes/admin.conf ~/.kube/config
    sudo chown "$(id -u):$(id -g)" ~/.kube/config

The output ends with a join command that contains a token. It is valid for
24 hours and not needed here. Do not store it anywhere.

Checks:

    kubectl get nodes                   # node-01 NotReady
    kubectl get pods -A                 # CoreDNS Pending, the rest Running
    kubectl get node node-01 -o jsonpath='{.spec.taints}{"\n"}'
    kubectl -n kube-system get ds kube-proxy
    sudo grep -i shutdown /var/lib/kubelet/config.yaml

- `NotReady` and `Pending` are expected: there is no pod network yet.
- The taints must show `node.kubernetes.io/not-ready` only. A taint
  `node-role.kubernetes.io/control-plane` would keep all ordinary pods off
  the node.
- `kube-proxy` must be `NotFound`. Cilium replaces it.
- The kubelet values must be `2m0s` and `30s`.

## 5. Network

Gateway API CRDs first. Cilium requires them before Gateway API is enabled.

    kubectl apply --server-side -f components/gateway-api-crds/standard-install.yaml

Cilium:

    helm repo add cilium https://helm.cilium.io
    helm install cilium cilium/cilium --version 1.19.4 \
      -n kube-system -f components/cilium/values.yaml
    kubectl -n kube-system rollout status ds/cilium
    cilium status --wait

The Cilium Helm release is not managed by Argo CD. Upgrade it with
`helm upgrade` and the same values file.

Checks:

    kubectl get nodes                                     # Ready
    kubectl -n kube-system get pods -l k8s-app=kube-dns   # Running
    kubectl get gatewayclass                              # cilium, ACCEPTED True
    cilium config view | grep -E 'kube-proxy-replacement|enable-wireguard|enable-gateway-api|enable-l2-announcements'

Recommended after a new installation, takes 10 to 20 minutes:

    cilium connectivity test
    kubectl get ns -o name | grep cilium-test | xargs -r kubectl delete

A failing `check-log-errors` with "no kind is registered for the type
v1alpha2.TLSRouteList" in the log of the operator is harmless. The CRDs
come from the standard channel, which has no TLSRoute. Seen in July 2026.
The test does not always remove its namespaces, hence the second command.

## 6. Argo CD

    helm repo add argo https://argoproj.github.io/argo-helm
    helm install argocd argo/argo-cd --version 10.10.2 \
      -n argocd --create-namespace \
      -f components/argocd/values.yaml --wait --timeout 10m

Use the chart version from `apps/argocd.yaml`. The release name must be
`argocd`.

Root application:

    kubectl apply -f bootstrap/root.yaml

From here on Argo CD installs everything under `apps/` and manages itself.
Do not use `helm upgrade` for Argo CD after this step.

Checks, a few minutes later:

    kubectl get applications -n argocd      # all Synced and Healthy
    kubectl -n gateway get gateway lab      # 192.168.1.240, PROGRAMMED True

From the workstation:

    curl -s -o /dev/null -w '%{http_code}\n' http://hubble.lab.home.arpa/    # 200

## 7. After the bootstrap

Argo CD admin password. Read the initial one, change it in the UI, then
delete the secret:

    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
    kubectl -n argocd delete secret argocd-initial-admin-secret

The UI has no route at the gateway yet. Open it through an SSH tunnel from
the workstation and a port-forward in that session, user `admin`, at
`https://localhost:8080`:

    ssh -L 8080:localhost:8080 <user>@192.168.1.51
    kubectl port-forward svc/argocd-server -n argocd 8080:443

Run the playbook a second time. It starts the two timers, which it only
enables while there is no cluster. Nothing else may change:

    cd ~/lab-platform/ansible
    ansible-playbook node.yaml -K

First etcd snapshot:

    sudo systemctl start etcd-snapshot.service
    sudo ls -lh /var/backups/etcd

Power cycle. Switch off, switch on, wait about three minutes:

    sudo node-off

    kubectl get pods -A
    kubectl get applications -n argocd
    systemctl status k8s-prune-terminated.service

What a new bootstrap does not bring back:

- The Argo CD admin password. It is the initial one again.
- Write access to this repository after a disk failure. The deploy key lives
  on the node only. Create a new one and register it on GitHub.
- Data on persistent volumes and the keys of Sealed Secrets, once the
  platform has them.

## Reset a node

To repeat sections 3 to 7 on a node that already ran them. The script
removes the cluster and everything the playbook installed. It keeps the
operating system, the network configuration, the volumes and
`/var/lib/local-path-provisioner`. Details are in its header.

Before: everything in `~/lab-platform` is committed and pushed.

    cd ~/lab-platform && git status
    sudo ./bootstrap/teardown-node.sh
    sudo reboot

The reboot is part of the procedure. The script leaves the Cilium
interfaces alone on purpose, only the reboot removes them. Deleting them on
a running node cuts the network connection of the machine.

After the reboot continue with section 3, without the `git clone`.

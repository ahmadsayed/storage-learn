# The Longhorn lab — replicated volumes on two real VMs

Longhorn is the pragmatic answer to "I want replicated storage without running
Ceph": one Helm chart, a DaemonSet, and volumes made of one independent copy per
node. This lab runs it on **two Ubuntu VMs running k3s**, because that is what
Longhorn needs — a real node with a real disk and a real `iscsid`.

The lab is separate from the Ceph lab in substrate as well as in subject: Ceph's
data path is the kernel RBD client and it runs happily on kind, while Longhorn's
runs through a userspace iSCSI daemon and needs the node to be a node.

## The lessons (run them in order)

| # | Lesson | What you do |
|---|--------|-------------|
| **00** | [The Longhorn lab cluster](00-cluster-setup/README.md) | two VMs running k3s, built by one script, with no host root required |
| **01** | [Longhorn](01-longhorn/README.md) | install, disks, a volume a pod mounts, data that outlives the pod's node, and a node killed and recovered |

## What this lab demonstrates

| | Status |
|---|---|
| Cluster: two k3s nodes on real VMs, `iscsid` active, ext4 data path | **works** |
| Longhorn install (one Helm chart, 14 pods) | **works, verified** |
| Node and disk accounting (18.3GB disk, 12.3GB available, ext4 detected) | **works, verified** |
| Volume provisioning: **two replicas, one per node** | **works, verified** |
| A pod mounts the volume and gets a real filesystem | **works, verified** |
| The data outlives the pod's node: pod moves, file reads back | **works, verified** |
| A node is killed: volume `degraded` but **still serving writes** | **works, verified** |
| The node returns: replica rebuilds, volume back to `healthy` in ~45s | **works, verified** |
| The kind attempt, and why it failed | documented in [Lesson 01's appendix](01-longhorn/README.md), including the two explanations this course got wrong first |

## Requirements

| Tool | Why |
|------|-----|
| **qemu** (`qemu-system-x86_64`, `qemu-img`) + **`/dev/kvm`** | the VMs run as your user; KVM makes them fast |
| **`genisoimage`** or **`mkisofs`** | the cloud-init seed ISOs |
| **`kubectl`** and **`helm` ≥ v3.13** | driving k3s and installing Longhorn |
| **~4GB RAM free**, ~25GB disk, Internet access | two VMs at 1.75GB, plus a 600MB image and Longhorn's images |

**No host root is needed.** qemu uses KVM as your user, the VMs get internet through
qemu's user-mode NAT, and they are joined to each other by a multicast socket rather
than a bridge or tap device.

## How to run it

```bash
cd 00-cluster-setup
./vm.sh up                       # image, VMs, k3s, kubeconfig — a few minutes
export KUBECONFIG=$PWD/k3s.yaml

kubectl label node k3s-server k3s-agent node.longhorn.io/create-default-disk=true --overwrite
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
  --version 1.12.1 -f ../01-longhorn/values.yaml
```

Then work through Lesson 01. The failure drill stops a VM and starts it again; its
disk keeps its state, so that is a reboot and not a reinstall.

## Do not run this next to the other labs on a small machine

Two VMs plus the Ceph lab's kind cluster plus anything else of yours will not fit in
15GB. Park them when they are not in use:

```bash
./vm.sh down              # stop the VMs (disks keep their state)
../../cleanup.sh ceph     # or stop the Ceph lab
```

## Cleanup

```bash
./00-cluster-setup/vm.sh destroy     # stop the VMs and delete their disks
./00-cluster-setup/vm.sh down        # or just stop them
../../cleanup.sh longhorn            # both of the above, chosen automatically
```

`cleanup.sh` checks what exists: it removes the Ceph lab's kind cluster only if that
cluster is there, and destroys the VMs only if they are there.

# Lesson 00 — The Longhorn lab cluster: two real VMs running k3s

## Glossary

| Term | What it means |
|------|---------------|
| **k3s** | a single-binary Kubernetes distribution; one server node is a whole control plane |
| **cloud-init** | the standard way to configure a cloud image on first boot — users, packages, network, commands |
| **KVM** | Linux's hardware virtualisation; `/dev/kvm` lets qemu run a VM at near-native speed |
| **user-mode networking** | qemu's built-in NAT: internet for the guest, forwarded ports inward, no root and no bridge |
| **multicast socket link** | qemu's `-netdev socket,mcast=…`: a virtual L2 segment between VMs, also without root |
| **data path** | where Longhorn keeps replica files: `/var/lib/longhorn`, and it must be ext4 or XFS |
| **iscsid** | the iSCSI initiator daemon; Longhorn's data engine drives it, and on a real node it is an ordinary systemd service |

This lesson builds the Longhorn lab's cluster: **two Ubuntu VMs running k3s**,
wired to each other and to the internet, with qemu running as your normal user.

> 🏭 **Why not kind?** Because Longhorn needs a real node, and the reason is
> specific rather than superstitious: its data engine drives iSCSI through
> `iscsid`, and its disk accounting resolves the data path to the filesystem
> *underneath* that path. Inside a kind node the path is a nested loop mount that
> the storage manager cannot see as a mount, so the same resolution lands on the
> host's filesystem — btrfs, with zero bytes free — and no replica is ever
> scheduled. [Lesson 01](01-longhorn/README.md) documents that investigation in
> full, including the parts this course got wrong along the way.

## Files

- `vm.sh` — creates, starts, stops and destroys the VMs, and fetches the kubeconfig. Run it with no arguments to see its subcommands.

## Requirements

| Tool | Why |
|------|-----|
| **qemu** (`qemu-system-x86_64`, `qemu-img`) and **`/dev/kvm`** | the VMs; KVM is what makes them fast enough to be pleasant |
| **`genisoimage`** (or `mkisofs`) | building the cloud-init seed ISO |
| **`kubectl`**, and `helm` for Lesson 01 | driving the cluster through the forwarded API port |
| **~4GB RAM free**, ~25GB disk | two VMs at 1.75GB, plus a sparse 20GB disk each |
| **Internet access** | the Ubuntu cloud image (~600MB, once) and the k3s install script |

**No root on the host is required.** That is the point of the design: KVM is used
as your user, internet comes from qemu's user-mode NAT, and the two VMs are joined
by a multicast socket instead of a bridge or a tap device.

## Step 1 — Build the cluster

```bash
./vm.sh up
```

One command: it downloads the image if needed, generates an SSH key, writes a
cloud-init seed for each VM, boots them, waits for k3s to install and join, and
fetches the kubeconfig.

```console
$ ./vm.sh up
== downloading the Ubuntu cloud image (~600MB, once)
== server VM
  server VM started (ssh 127.0.0.1:2222, api 127.0.0.1:6443)
  waiting for cloud-init to install k3s (a few minutes)
  kubeconfig: export KUBECONFIG=/…/longhorn-lab/00-cluster-setup/k3s.yaml
== agent VM
  agent VM started (ssh 127.0.0.1:2223, api 127.0.0.1:6444)
== cluster ready
NAME         STATUS   ROLES           AGE   VERSION        INTERNAL-IP     KERNEL-VERSION
k3s-agent    Ready    <none>          13s   v1.36.4+k3s1   192.168.76.11   6.8.0-139-generic
k3s-server   Ready    control-plane   79s   v1.36.4+k3s1   192.168.76.10   6.8.0-139-generic
```

```bash
export KUBECONFIG=$PWD/k3s.yaml      # the k3s API, forwarded to 127.0.0.1:6443
kubectl get nodes -o wide
```

## Step 2 — Check the two things Longhorn depends on

```bash
./vm.sh ssh server -- 'systemctl is-active iscsid; findmnt -no FSTYPE,SOURCE /'
```

```console
$ ./vm.sh ssh server -- '…'
active
ext4   /dev/vda1
```

That is the whole prerequisite list, and on a real node it is boring:

| Requirement | On this VM | How the kind lab had to fake it |
|-------------|------------|--------------------------------|
| `iscsid` running | `active` — an ordinary systemd service | started by hand, and it fought systemd's socket unit for the control socket |
| data path on ext4/XFS | the root filesystem *is* ext4 | an ext4 built on a loop device, because this workstation's root is btrfs |
| a real disk | `/dev/vda1`, a 20GB virtio disk | a sparse file pretending to be a disk |
| real namespaces | a real kernel; pods get their own namespaces normally | the "node" was itself a container |

> 🎓 **Insight:** the data path row is the one that decided this lab's substrate.
> Longhorn does not merely want space — it wants to know which filesystem it is
> standing on, and a nested mount inside a container node does not answer that
> question the way a real disk does.

## Step 3 — Label the nodes as storage nodes

```bash
kubectl label node k3s-server k3s-agent node.longhorn.io/create-default-disk=true --overwrite
```

`values.yaml` in the next lesson sets `createDefaultDiskLabeledNodes: true`, so
only labelled nodes become storage nodes. Two nodes means two replicas per volume:
enough for a real redundancy story and for the failure drill in Lesson 01, with no
third node to spare for a control plane that also stores data.

## Lifecycle

| Command | What it does |
|---------|--------------|
| `./vm.sh status` | which VMs are running, and the cluster's nodes |
| `./vm.sh stop server` / `./vm.sh start server` | stop or start one VM; **the disk keeps its state** — this is a reboot, not a reinstall |
| `./vm.sh down` | stop both VMs |
| `./vm.sh ssh agent -- <cmd>` | run something inside a node |
| `./vm.sh kubeconfig` | re-fetch the kubeconfig |
| `./vm.sh destroy` | stop both VMs and delete their disks |

> ⚠️ **Warning — a bug this lab shipped once.** The first version of `vm.sh`
> recreated a VM's disk overlay on every start, so "restart the node" silently
> became "reinstall the node", and the failure drill's recovery turned into a fresh
> node with an empty data path. `start` now creates a disk only if there is none,
> and it refuses to fail quietly: if qemu cannot start, it prints the guest's
> console tail instead of leaving you waiting for a node that will never appear.

## Production note

- **This is a lab, not a deployment.** Two VMs on one laptop share one disk and one
  CPU: the redundancy is real at the Kubernetes and Longhorn layers and fictional at
  the hardware layer.
- **`--disable traefik --disable servicelb`** stops k3s from deploying an ingress
  and a load balancer nobody asked for. `--flannel-iface intervm` pins the pod
  network to the inter-VM link, which is what makes cross-node pod traffic work.
- **The VMs reach the host only through forwarded ports**, because they sit behind
  qemu's user-mode NAT. Fine for a lab; production has real networking.
- **On a real cluster you do none of this.** You install k3s (or anything else) on
  machines or cloud instances, and the two prerequisites above are simply true.

## Next

Continue to [Lesson 01 — Longhorn](01-longhorn/README.md).

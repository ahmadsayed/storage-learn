# Lesson 00 — The Longhorn lab cluster: three nodes, three fake disks, and iscsid

## Glossary

| Term | What it means |
|------|---------------|
| **kind** | Kubernetes IN Docker — each "node" is a container, so a whole cluster runs on one machine |
| **kindest/node** | the node image kind boots; here `v1.35.0`, a Debian 12 container running systemd, containerd and kubelet |
| **loop device** | a file presented to the kernel as a block device (`/dev/loop221`); the standard way to fake a disk |
| **data path** | the directory Longhorn keeps replicas in: `/var/lib/longhorn` by default, and it must be on ext4 or XFS |
| **iscsid** | the iSCSI initiator daemon; Longhorn's V1 data engine logs in to an iSCSI target through it |
| **socket activation** | systemd listens on a service's socket and starts the daemon when a client connects — which is why `iscsid` is not always running, and why that matters here |
| **abstract socket** | a unix socket with no file on disk (`@ISCSIADM_ABSTRACT_NAMESPACE`); scoped to a network namespace, so only a client in the *same* netns can reach it |

This lesson gives the Longhorn cluster its two prerequisites — a data path per node
and a working `iscsid` — and shows you how to check both, because "install it and
wait" is not enough for Longhorn on kind. The cluster is its own (`lhslab`); the
Ceph lab's `csilab` is untouched by anything here.

> 🧪 **Lab Hack** — real nodes have a disk and an init system. A kind node has a
> container filesystem and systemd with most units disabled, so both prerequisites
> are simulated. Every step says what the production equivalent is.

## Files

- `kind-config.yaml` — the cluster: 1 control-plane + 2 workers, pinned to `kindest/node:v1.35.0`.
- `prepare-disks.sh` — idempotent: loads `iscsi_tcp`, starts iscsid and reports its state, gives each node an ext4 data path.

## Step 1 — Create the cluster

```bash
kind create cluster --config kind-config.yaml
```

```console
$ kind create cluster --config kind-config.yaml
 • Ensuring node image (kindest/node:v1.35.0) 🖼  ...
 ✓ Ensuring node image (kindest/node:v1.35.0) 🖼
 • Preparing nodes 📦 📦 📦   ...
 ✓ Preparing nodes 📦 📦 📦
 • Writing configuration 📜  ...
 ✓ Writing configuration 📜
 • Starting control-plane 🕹️  ...
 ✓ Starting control-plane 🕹️
 • Installing CNI 🔌  ...
 ✓ Installing CNI 🔌
 • Installing StorageClass 💾  ...
 ✓ Installing StorageClass 💾
 • Joining worker nodes 🚜  ...
 ✓ Joining worker nodes 🚜
```

> 💡 **Tip:** pass `--kubeconfig ~/.kube/lhslab.yaml` and export `KUBECONFIG` if you
> also run the Ceph lab, so `kubectl delete` can never land on the wrong cluster.

Two things to do before installing Longhorn. First, remove kind's control-plane
taint — Longhorn counts **nodes** when it places replicas, and with two it can never
place the third replica of a three-replica volume:

```bash
kubectl taint node lhslab-control-plane node-role.kubernetes.io/control-plane-
```

> 🏭 **Production:** do not do that on a real cluster. Give the storage system
> tolerations instead — Longhorn needs them on *both* its own components and the
> system-managed pods: `longhornManager.tolerations` in the chart, plus the
> `taint-toleration` setting. Removing the taint was the lab's choice because it is
> one command and one less thing to misconfigure.

Second, prepare the nodes:

## Step 2 — Give each node a data path and an iscsid

```bash
./prepare-disks.sh
```

```console
$ ./prepare-disks.sh
== lhslab-control-plane — kernel modules
iscsi_tcp              28672  0

== lhslab-control-plane — iSCSI daemon
  iscsid.socket: active
  listener on @ISCSIADM_ABSTRACT_NAMESPACE: 1
  live iscsid processes: 2

== lhslab-control-plane — Longhorn data path (/var/lib/longhorn on /dev/loop220, 5G)
loop device attached
mounted
ext4   /dev/loop220 /var/lib/longhorn

== lhslab-worker — iSCSI daemon
  iscsid.socket: active
  listener on @ISCSIADM_ABSTRACT_NAMESPACE: 1
  live iscsid processes: 0          <- note this

== lhslab-worker — Longhorn data path (/var/lib/longhorn on /dev/loop221, 5G)
loop device attached
mounted
ext4   /dev/loop221 /var/lib/longhorn
...
--- lhslab-worker
ext4   /dev/loop221 /var/lib/longhorn
  iscsid processes: 0
```

Four things are load-bearing in that output.

| Step | Why it is here | Production equivalent |
|------|----------------|-----------------------|
| `modprobe iscsi_tcp` | Longhorn's engine needs the kernel iSCSI initiator. A kind node's `/lib/modules` is empty — `kind-config.yaml` mounts the host's read-only so the loader can resolve anything | loaded at boot |
| start `iscsid.socket` | `iscsiadm` talks to the daemon over an **abstract** socket, which exists only inside one network namespace. The unit makes systemd own it, so a client can connect at all | `systemctl enable --now iscsid` |
| watch the daemon's liveness | Longhorn does not call `iscsiadm` directly: it enters a **live iscsid process's** namespaces (`nsenter --mount=/proc/<iscsid>/ns/mnt --net=...`). In a kind node the daemon is socket-activated and **exits again after serving**, so this count is often `0` — and that is one of the two things that break Longhorn here | the daemon runs for the life of the node |
| ext4 on `/dev/loop22N` | Longhorn rejects a data path that is not on an extent-based filesystem, and this workstation's root filesystem is btrfs, which Longhorn does not support. Each node gets its own ext4 | a data disk formatted ext4 or XFS, mounted at `/var/lib/longhorn` |

> ⚠️ **Warning:** loop devices are kernel-global, so this lab uses 220+ while the
> Ceph lab uses 100/101. Two nodes attaching the same loop index would be one
> device with two owners.

> 🎓 **Insight:** note that `live iscsid processes` is **0 on one node and 2 on the
> others** — the same script, the same image, different outcomes, because the
> daemon is started on demand and exits when idle. Keep that in mind: Lesson 01
> shows Longhorn failing for a reason that survives both cases, and the daemon
> lifecycle is the *second* thing in its way, not the first.

## Verify

```bash
for n in lhslab-control-plane lhslab-worker lhslab-worker2; do
  echo "## $n"
  docker exec $n sh -c 'findmnt -no FSTYPE,SOURCE,TARGET /var/lib/longhorn'
  docker exec $n sh -c 'echo -n "  iscsid: "; pgrep -x iscsid | wc -l; echo -n "  socket listener: "; ss -xl | grep -c ISCSIADM'
done
```

## Expected outcome

```console
## lhslab-control-plane
ext4   /dev/loop220 /var/lib/longhorn
  iscsid: 2
  socket listener: 1
## lhslab-worker
ext4   /dev/loop221 /var/lib/longhorn
  iscsid: 0
  socket listener: 1
## lhslab-worker2
ext4   /dev/loop222 /var/lib/longhorn
  iscsid: 2
  socket listener: 1
```

Every node has ext4 at the data path and a listening socket. The daemon count is
the part that varies, and Lesson 01 explains what it costs and why fixing it is not
enough.

## Production note

- **The data path must be a real filesystem, and Longhorn means it.** ext4 or XFS
  only; btrfs is an open feature request, not a supported option. On a real node
  this is a disk you partitioned once, not something a script does.
- **`iscsid` is a hard dependency of the V1 data engine**, and every Longhorn
  prerequisite check (`longhornctl check preflight`) looks for exactly these two
  things: the package and the running daemon.
- **The mount does not survive a node restart.** Neither a real node reboot nor a
  kind container restart keeps it, and `prepare-disks.sh` exists to be re-run.
- **This lab's cluster can run next to the Ceph lab's**, but not comfortably on a
  laptop: each storage system brings real daemons. Stop one before starting the
  other (`../../cleanup.sh ceph`, or `kind delete cluster --name csilab`).

## Next

Continue to [Lesson 01 — Longhorn](../01-longhorn/README.md).

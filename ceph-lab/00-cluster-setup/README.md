# Lesson 00 — The Ceph lab cluster: three nodes and two fake disks

## Glossary

| Term | What it means |
|------|---------------|
| **kind** | Kubernetes IN Docker — each "node" is a container, so a whole cluster runs on one machine |
| **kindest/node** | the node image kind boots; here `v1.35.0`, a Debian 12 container running systemd, containerd and kubelet |
| **loop device** | a file presented to the kernel as a block device (`/dev/loop100`); the standard way to fake a disk |
| **devtmpfs** | the kernel-managed `/dev`; a new device appears there the moment the kernel creates it |
| **udev** | the userspace daemon that records device properties in `/run/udev/data`; `ceph-volume` reads that database to identify a disk |
| **krbd** | the kernel RBD client, which maps a Ceph image to `/dev/rbdN` |
| **OSD** | object storage daemon — one per disk; the thing that will claim our fake disk |

This lesson builds the Ceph lab's cluster and nothing else: three nodes, and for
each **worker** the one thing Ceph actually needs — an empty block device. The
proof at the end is `lsblk` showing your fake disks where a real `/dev/sdb` would
be. It is a separate cluster from the Longhorn lab on purpose; Ceph and Longhorn
want different things from a node, and this lab only sets up what Ceph wants.

> 🧪 **Lab Hack** — this lesson is honest fakery. Real clusters do not create
> disks with `truncate` and `losetup`; a node has a real device or it does not.
> Every step below says what the production equivalent is, and the later lessons
> never pretend the loop device is a disk array.

## Files

- `kind-config.yaml` — the cluster: 1 control-plane + 2 workers, pinned to `kindest/node:v1.35.0`.
- `prepare-disks.sh` — idempotent; loads the RBD module, makes `/sys` writable, creates `/dev/rbd*`, and gives each worker a fake disk.

## Step 1 — Create the cluster

```bash
kind create cluster --config kind-config.yaml
```

> 💡 **Tip:** if you already keep other kind clusters, pass
> `--kubeconfig ../../.csi-lab.kubeconfig` (so the file lands at the repository
> root) and then `export KUBECONFIG=…/.csi-lab.kubeconfig`, so a later
> `kubectl delete` can never land on the wrong cluster. That is how this course
> was recorded, and it is the file `cleanup.sh` looks for first.

kind prints one line per phase and takes about a minute:

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

## Step 2 — Look at what kind gave you (and what it did not)

```bash
kubectl get nodes -o wide
kubectl get storageclass
kubectl get csidrivers
```

```console
$ kubectl get nodes -o wide
NAME                   STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...  CONTAINER-RUNTIME
csilab-control-plane   Ready    control-plane   98s   v1.35.0   172.19.0.4    ...  containerd://2.2.0
csilab-worker          Ready    <none>          83s   v1.35.0   172.19.0.3    ...  containerd://2.2.0
csilab-worker2         Ready    <none>          84s   v1.35.0   172.19.0.2    ...  containerd://2.2.0

$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false

$ kubectl get csidrivers
No resources found

$ kubectl version
Client Version: v1.36.4
Server Version: v1.35.0
```

Read those three together, because they are the course in miniature:

| What you see | Why it matters |
|--------------|----------------|
| `standard` StorageClass exists | something can already provision volumes — but it is `rancher.io/local-path`, which is **not** a CSI driver |
| `kubectl get csidrivers` is empty | the CSI interface is part of Kubernetes; a **driver** is not. This cluster has none until you install one |
| `ALLOWVOLUMEEXPANSION: false` | and that class cannot grow a volume. Both facts change the moment Rook arrives |

> 🎓 **Insight:** `local-path` is the perfect foil. It is dynamic, it binds PVCs,
> and it is useless the moment a pod moves to another node, because its "volume" is
> a directory on one machine. If you want to see what that means before installing
> Ceph, the shared lesson [CSI fundamentals](../../00-csi-fundamentals/README.md)
> runs on this cluster.

Two more facts, checked rather than assumed:

```bash
stat -fc %T /sys/fs/cgroup      # k8s 1.35 dropped cgroup v1 entirely
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
```

```console
$ stat -fc %T /sys/fs/cgroup
cgroup2fs

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
NAME                   TAINTS
csilab-control-plane   node-role.kubernetes.io/control-plane
csilab-worker          <none>
csilab-worker2         <none>
```

kind taints its control-plane node, exactly like a real cluster. This lab wants
all three nodes usable — Ceph's monitor, manager and the pods that consume storage
should have somewhere to go, and Rook's own CI runs its whole suite on a single
untainted node — so remove it:

```bash
kubectl taint node csilab-control-plane node-role.kubernetes.io/control-plane-
```

```console
$ kubectl taint node csilab-control-plane node-role.kubernetes.io/control-plane-
node/csilab-control-plane untainted
```

> 🏭 **Production:** do not copy that line into a real cluster. There the control
> plane is tainted on purpose and storage runs on dedicated workers; the
> equivalent real-world move is to give the storage system *tolerations*
> (`CephCluster.spec.placement.tolerations` for Rook, `longhornManager.tolerations`
> for Longhorn) instead of removing the taint from the node.

## Step 3 — Give the workers their disks

```bash
./prepare-disks.sh
```

The script is idempotent — run it again after any node restart. It does four
things per worker node, and each exists because Rook would otherwise fail for a
reason that has nothing to do with the exercise:

| Step | Why it is here | Production equivalent |
|------|----------------|-----------------------|
| `modprobe rbd` | Ceph's CSI plugin maps images through the kernel RBD client. A kind node's `/lib/modules` is empty — `kind-config.yaml` mounts the host's read-only so the module loader can resolve anything at all | loaded by the OS at boot |
| remount `/sys` read-write | krbd registers a mapped image by writing `/sys/bus/rbd/add`; kind mounts `/sys` read-only inside nodes, so every RBD volume otherwise hangs in `ContainerCreating` with `rbd: sysfs write failed`. Rook's CI remounts it for the same reason | `/sys` is writable on a normal node |
| `mknod /dev/rbd0..7` | a kind node's `/dev` is a private tmpfs, not the kernel's devtmpfs, so the kernel's auto-created `/dev/rbd0` never appears there. ceph-csi maps with `--options noudev` and then looks for exactly that path | devtmpfs creates the node when the kernel maps the image |
| `loop100` / `loop101` | an OSD claims a **raw, empty block device**. kind nodes have none — only the filesystem they booted from | a spare disk: `/dev/sdb`, unformatted, no partitions |

```console
$ ./prepare-disks.sh
== csilab-worker — kernel modules
rbd                   159744  0

== csilab-worker — writable /sys
/sys   rw,nosuid,nodev,noexec,relatime

== csilab-worker — /dev/rbd* device nodes
brw-r--r-- 1 root root 251, 0 Sep 13 05:04 /dev/rbd0

== csilab-worker — fake OSD disk (/dev/loop100, 8G)
already attached to the right backing file
/dev/loop100         0      0         0  0 /var/lib/rook-osd/osd.img    0     512
left /dev/loop100 signatures alone (WIPE_OSD_DEVICE=1 blanks it on purpose)

== csilab-worker2 — fake OSD disk (/dev/loop101, 8G)      # trimmed: the same four
already attached to the right backing file                # sections run per node,
/dev/loop101         0      0         0  0 /var/lib/rook-osd/osd.img    0     512
...                                                       # then a == summary
```

> ⚠️ **Warning:** loop devices are kernel-global. `/dev/loop100` attached in one
> node is the *same* device another node would see if it attached that number, so
> the script gives each node its own index. Two OSDs sharing one backing file
> would corrupt data silently.

That `signatures alone` line is not filler — it is a bug this course found the
hard way:

> ⚠️ **The script used to run `wipefs -a` on every OSD device.** Run against a
> cluster that already had an OSD on that device, it destroyed the OSD's BlueStore
> metadata, and the OSD pod then failed in its `expand-bluefs` init container —
> which reads like a kind or loop-device limitation and is not. Wiping is now
> opt-in (`WIPE_OSD_DEVICE=1`), and
> [Lesson 02](../02-day2/README.md) tells that story in full, including how the
> mistake was diagnosed.

## Verify

```bash
for n in csilab-worker csilab-worker2; do
  echo "## $n"
  docker exec $n sh -c 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep loop'
done
```

## Expected outcome

```console
######## csilab-worker ########
loop100         8G loop
loop101         8G loop

######## csilab-worker2 ########
loop100         8G loop
loop101         8G loop
```

Every node lists **both** loop devices, and neither of them is mounted: `lsblk`
reads `/sys/block`, which is the same kernel for every "node". That is not a
detail to skim — it is why the Ceph lab's cluster configuration names one device
per node instead of saying "use them all", and
[Lesson 01](../01-rook-ceph/README.md) shows what that log looks like.

The other half of the story is udev. `ceph-volume` refuses to prepare a device it
cannot find in udev's database, and a kind node runs no udev of its own — which is
why `kind-config.yaml` mounts the host's `/run/udev` read-through. The host daemon
sees the loop device the moment you attach it:

```console
$ cat /run/udev/data/b7:100        # major 7, minor 100 = /dev/loop100
S:disk/by-diskseq/20
E:ID_BLOCK_SUBSYSTEM=loop
E:ID_LOOP_BACKING_DEVICE=0:38
E:ID_LOOP_BACKING_FILENAME=/var/lib/rook-osd/osd.img
```

> 🎓 **Insight:** that entry is the difference between `rook-ceph-osd-prepare`
> finding a disk and logging `No udev data could be retrieved`, giving up, and
> leaving you with a Ceph cluster that has no OSDs. Rook's own CI runs on kind and
> mounts `/dev`, `/var/lib/rook` and `/run/udev` for these reasons; the mount list
> in `kind-config.yaml` is deliberately the same shape.

## Production note

Nothing here survives scrutiny as production practice, and that is the point: the
*shape* is real (three nodes, a disk per storage node, one copy per host), the
*substance* is simulated.

- **Capacity and speed are fiction.** Eight gigabytes of sparse file on one NVMe
  says nothing about a real disk, and every "node" shares one page cache. This
  course never publishes IOPS or throughput numbers from this lab.
- **A loop device cannot fail the way a disk fails.** Lesson 02 stops node
  *containers* to get a failure that is at least real at the Kubernetes layer.
- **`dataDirHostPath` lives inside the node container.** Deleting the cluster
  deletes it, so `../../cleanup.sh` detaches the loop devices *before* `kind
  delete`, or the host kernel is left holding devices whose backing files no
  longer exist.

## Next

Continue to [Lesson 01 — Rook Ceph: block storage and a shared filesystem](../01-rook-ceph/README.md).

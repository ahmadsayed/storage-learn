# Lesson 00 — The lab cluster: three nodes and five fake disks

## Glossary

| Term | What it means |
|------|---------------|
| **kind** | Kubernetes IN Docker — each "node" is a container, so a whole cluster runs on one machine |
| **kindest/node** | the node image kind boots; here `v1.35.0`, a Debian 12 container running systemd, containerd and kubelet |
| **loop device** | a file presented to the kernel as a block device (`/dev/loop100`); the standard way to fake a disk |
| **devtmpfs** | the kernel-managed `/dev`; a new device appears there the moment the kernel creates it |
| **udev** | the userspace daemon that records device properties in `/run/udev/data`; `ceph-volume` reads that database to identify a disk |
| **iscsid** | the iSCSI initiator daemon; Longhorn's storage engine talks to the kernel through it |
| **StorageClass** | the "which storage and how" object a PersistentVolumeClaim asks for |
| **CSI** | Container Storage Interface — the socket protocol a storage driver speaks to kubelet |

This lesson builds the lab and nothing else: a three-node cluster, and for each
node the two things a storage system actually needs — an empty block device and a
directory with space. The proof at the end is `lsblk` showing your fake disks
where a real `/dev/sdb` would be.

> 🧪 **Lab Hack** — this lesson is honest fakery. Real clusters do not create disks
> with `truncate` and `losetup`; a node has a real device or it does not. Every
> step below is marked with what the production equivalent is, and later lessons
> never pretend the loop device is a disk array.

## Files

- `kind-config.yaml` — the cluster: 1 control-plane + 2 workers, pinned to `kindest/node:v1.35.0`.
- `prepare-disks.sh` — idempotent; loads the kernel modules, starts `iscsid`, creates the loop-backed disks.

## Step 1 — Create the cluster

```bash
kind create cluster --config kind-config.yaml
```

> 💡 **Tip:** if you already keep kind clusters for other work, pass
> `--kubeconfig ~/.kube/csilab.yaml` and then `export KUBECONFIG=~/.kube/csilab.yaml`,
> so a later `kubectl delete` can never land on the wrong cluster. That is how this
> course was recorded.

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
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  94s

$ kubectl get csidrivers
No resources found

$ kubectl version
Client Version: v1.36.4
Server Version: v1.35.0
```

Read those three lines together, because they are the course in miniature:

| What you see | Why it matters |
|--------------|----------------|
| `standard` StorageClass exists | something can already provision volumes — but it is `rancher.io/local-path`, which is **not** a CSI driver |
| `kubectl get csidrivers` is empty | the CSI interface is part of Kubernetes; a **driver** is not. This cluster has none until you install one |
| `ALLOWVOLUMEEXPANSION: false` | and that local-path class cannot grow a volume. Both facts change the moment a real driver arrives |

> 🎓 **Insight:** `local-path` is the perfect foil for this course. It is dynamic,
> it binds PVCs, and it is completely useless the moment the pod moves to another
> node, because its "volume" is a directory on one machine. Lessons 02 and 03
> replace it with drivers that replicate.

Two more facts this cluster needs, both checked here rather than assumed:

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

kind taints its control-plane node, exactly like a real cluster. A storage course
wants three usable nodes — Longhorn counts *nodes* when it places replicas, and
with two the third replica is unschedulable forever. So remove it:

```bash
kubectl taint node csilab-control-plane node-role.kubernetes.io/control-plane-
```

```console
$ kubectl taint node csilab-control-plane node-role.kubernetes.io/control-plane-
node/csilab-control-plane untainted
```

> 🏭 **Production:** do not copy that line into a real cluster. There the control
> plane is tainted on purpose, and storage runs on dedicated workers. The
> equivalent real-world move is to give the storage system *tolerations* for the
> taint (`longhorn-manager.tolerations`, or Rook's `placement.tolerations`)
> instead of removing the taint from the node.

## Step 3 — Give the nodes their disks

```bash
./prepare-disks.sh
```

The script is idempotent — run it again after any node restart. It does four
things per node, and each one exists because a storage system would otherwise
fail on kind for a reason that has nothing to do with the exercise:

| Step | Why it is here | Production equivalent |
|------|----------------|-----------------------|
| `modprobe rbd iscsi_tcp` | Ceph's CSI plugin maps RBD images through the kernel, Longhorn drives iSCSI. A kind node's `/lib/modules` is empty — `kind-config.yaml` mounts the host's read-only so the module loader can resolve anything at all | the modules are loaded by the OS at boot |
| start `iscsid` | Longhorn's engine speaks to the kernel iSCSI initiator through this daemon. `kindest/node` **ships** `iscsiadm` and `iscsid` (since kind v0.20.0) but nothing starts them: a kind node has no enabled units | `systemctl enable --now iscsid` |
| `loop100`/`loop101` for Ceph | an OSD claims a **raw, empty block device**. kind nodes have none — only the filesystem they booted from | a spare disk: `/dev/sdb`, unformatted, no partitions |
| `loop110`–`loop112` for Longhorn | Longhorn wants a **directory on an extent-based filesystem** and rejects what this workstation has (btrfs root), so each node gets its own ext4 on a loop device | a data disk formatted ext4/XFS, mounted at `/var/lib/longhorn` |

> ⚠️ **Warning:** loop devices are kernel-global. `/dev/loop100` attached in one
> node is the *same* device another node would see if it attached that number, so
> the script gives every node its own index. Two OSDs sharing one backing file
> would corrupt data silently, and Ceph would not necessarily notice.

The script reports what it did:

```console
$ ./prepare-disks.sh
== csilab-control-plane — kernel modules
iscsi_tcp              28672  0
rbd                   159744  0

== csilab-control-plane — iSCSI daemon
iscsid started

== csilab-control-plane — no Ceph disk
not a Ceph storage node (only the workers get an OSD device)

== csilab-control-plane — Longhorn data path (/var/lib/longhorn on /dev/loop112, 5G)
loop device attached
mounted
/dev/loop112    4.9G   24K  4.6G   1% /var/lib/longhorn

== csilab-worker — fake OSD disk (/dev/loop100, 8G)
already attached
/dev/loop100         0      0         0  0 /var/lib/rook-osd/osd.img    0     512

== csilab-worker — Longhorn data path (/var/lib/longhorn on /dev/loop110, 5G)
loop device already attached
/var/lib/longhorn already a mount point
/dev/loop110    4.9G   24K  4.6G   1% /var/lib/longhorn
...
--- csilab-worker
/dev/loop110         0      0         0  0 /var/lib/longhorn-disk.img   0     512
/dev/loop100         0      0         0  0 /var/lib/rook-osd/osd.img    0     512
iscsid: running
```

That run was the second invocation, which is why the Ceph and Longhorn devices
say `already attached`: re-running is safe, and that matters because stopping a
node (Lesson 04 does exactly that) throws the *mount* away while the loop device
survives.

## Verify

```bash
for n in csilab-control-plane csilab-worker csilab-worker2; do
  echo "## $n"
  docker exec $n sh -c 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep loop'
  docker exec $n sh -c 'findmnt -no FSTYPE,SOURCE,TARGET /var/lib/longhorn'
done
```

## Expected outcome

```console
######## csilab-control-plane ########
loop100         8G loop
loop101         8G loop
loop110         5G loop
loop111         5G loop
loop112         5G loop /var/lib/longhorn
ext4   /dev/loop112 /var/lib/longhorn

######## csilab-worker ########
loop100         8G loop
loop101         8G loop
loop110         5G loop /var/lib/longhorn
loop111         5G loop
loop112         5G loop
ext4   /dev/loop110 /var/lib/longhorn

######## csilab-worker2 ########
loop100         8G loop
loop101         8G loop
loop110         5G loop
loop111         5G loop /var/lib/longhorn
loop112         5G loop
ext4   /dev/loop111 /var/lib/longhorn
```

Every node lists **all five** loop devices, but only its own is mounted: `lsblk`
reads `/sys/block`, which is the same kernel for every "node". That is not a
detail to skim — it is the reason Lesson 02 must tell Rook *which* device belongs
to *which* node instead of saying "use them all".

The other half of the story is udev. `ceph-volume` refuses to prepare a device it
cannot find in udev's database, and a kind node runs no udev of its own — which
is why `kind-config.yaml` mounts the host's `/run/udev` read-through. The host
daemon sees the loop device the moment you attach it:

```console
$ cat /run/udev/data/b7:100        # major 7, minor 100 = /dev/loop100
S:disk/by-diskseq/20
E:ID_BLOCK_SUBSYSTEM=loop
E:ID_LOOP_BACKING_DEVICE=0:38
E:ID_LOOP_BACKING_FILENAME=/var/lib/rook-osd/osd.img
```

> 🎓 **Insight:** that entry is the difference between `rook-ceph-osd-prepare`
> finding a disk and logging `No udev data could be retrieved`, giving up, and
> leaving you with a Ceph cluster that has no OSDs. Rook's own CI runs on kind
> and mounts `/dev`, `/var/lib/rook` and `/run/udev` for these reasons; the mount
> list in `kind-config.yaml` is deliberately the same shape.

## Production note

Nothing in this lesson survives scrutiny as production practice, and that is the
point: the *shape* is real (three nodes, a disk per storage node, a data
directory per node), the *substance* is simulated.

- **Capacity and speed are fiction.** Eight gigabytes of sparse file on one NVMe
  says nothing about a real disk, and every "node" shares one page cache. This
  course never publishes IOPS or throughput numbers from this lab.
- **A loop device cannot fail the way a disk fails.** Lesson 04 stops node
  *containers* to get a failure that is at least real at the Kubernetes layer.
- **`dataDirHostPath` and the Longhorn data path live inside the node container.**
  Deleting the cluster deletes them, so `../cleanup.sh` detaches the loop devices
  *before* `kind delete`, or the host kernel is left holding devices whose backing
  files no longer exist.

## Next

Continue to [Lesson 01 — PV, PVC, StorageClass, and where CSI plugs in](../01-csi-fundamentals/README.md).

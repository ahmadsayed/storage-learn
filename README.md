# CSI Storage in Kubernetes — two hands-on labs

Every pod that writes a file has already made a storage decision, whether or not
anyone made it on purpose. These labs are about that decision: what a
`PersistentVolumeClaim` really is, what a CSI driver does behind the socket, and
what changes when the storage behind a claim is **replicated across nodes**
instead of sitting in a directory on one machine.

Two storage systems, two labs, **two separate kind clusters**:

| Lab | Cluster | What it answers |
|-----|---------|-----------------|
| [**Ceph lab**](ceph-lab/README.md) | kind, `csilab` | What does a real distributed storage system look like on Kubernetes — and what does it cost to run? |
| [**Longhorn lab**](longhorn-lab/README.md) | **two VMs** running k3s | How far does a single Helm chart get you, with a real disk and a real `iscsid` underneath it? |

They are not merged on purpose. Ceph wants an **empty block device** per storage
node and Longhorn wants **a directory on a real filesystem**; Ceph's data path is the
kernel RBD client, and Longhorn's is an iSCSI login through a userspace daemon whose
engine also depends on how the storage manager sees the node. They even need
different substrates: Ceph runs well on kind, Longhorn needs real nodes, so its lab
uses VMs. Each lab stands alone, and [`cleanup.sh`](cleanup.sh) removes whichever of
them exists.

## The shared lesson

| # | Lesson | What you do |
|---|--------|-------------|
| **00** | [CSI fundamentals: PV, PVC, StorageClass, and where CSI plugs in](00-csi-fundamentals/README.md) | static vs dynamic provisioning, then the Kubernetes reference CSI driver, its socket, a `VolumeAttachment`, and a snapshot/restore |

Run it on whichever lab cluster you have up — it needs a cluster with **no** CSI
driver yet, and it is where `local-path` (dynamic, not CSI) and a real CSI driver
get compared side by side. It was recorded on the Ceph lab's cluster.

## The Ceph lab

| # | Lesson | What you do |
|---|--------|-------------|
| **00** | [The Ceph lab cluster](ceph-lab/00-cluster-setup/README.md) | kind + two fake disks, udev, a writable `/sys`, `/dev/rbd*` |
| **01** | [Rook Ceph: block storage and a shared filesystem](ceph-lab/01-rook-ceph/README.md) | Rook v1.20.7, 2 OSDs on 2 hosts, `HEALTH_OK`, a volume mounted as `/dev/rbd0`, RWX from CephFS |
| **02** | [Day-2 operations](ceph-lab/02-day2/README.md) | online expansion, CSI snapshot and restore, killing a storage node, serving reads while degraded |

## The Longhorn lab

| # | Lesson | What you do |
|---|--------|-------------|
| **00** | [The Longhorn lab cluster](longhorn-lab/00-cluster-setup/README.md) | two Ubuntu VMs running k3s, built by one script, with no host root needed |
| **01** | [Longhorn](longhorn-lab/01-longhorn/README.md) | install, disks, a mounted volume, data that outlives the pod's node, a node killed and recovered — plus why this lab is not on kind |

![One PVC, three realities](diagrams/one-pvc-three-realities.svg)

> The diagram is the mental model for both labs: the pod only ever names a PVC.
> Whether that claim becomes a directory on one node, an RBD image replicated
> across two OSDs, or three synchronous replicas of a sparse file is decided by one
> line — `storageClassName` — and everything after that is the driver's business.

## Requirements

| Tool | Why |
|------|-----|
| **Docker** + **kind** ≥ v0.31 | the Ceph lab's cluster |
| **qemu** + **`/dev/kvm`** + **`genisoimage`** | the Longhorn lab's two VMs (no host root needed) |
| **kubectl**, **git**, **helm** ≥ v3.13 | driving the clusters and installing the storage systems |
| **Internet access** | node images, plus ~1GB of Ceph or ~500MB of Longhorn images |
| **~4GB of free RAM per lab** | do not run both clusters at once on a laptop; each storage system brings real daemons |
| **A disposable machine** | Rook's OSD discovery gets access to device nodes (it will see your real disks). Lesson 01 of the Ceph lab shows that log line, and explains why each lab names its devices explicitly |

No GPU is needed. Linux is assumed: both labs reach into Docker, and the Ceph lab
stops a node container to simulate a failure.

## How to run them

```bash
# Ceph lab
cd ceph-lab/00-cluster-setup
kind create cluster --config kind-config.yaml
./prepare-disks.sh

# Longhorn lab, when you want it (stop the Ceph cluster first on a small machine)
cd longhorn-lab/00-cluster-setup
./vm.sh up                # two VMs, k3s, kubeconfig — a few minutes
export KUBECONFIG=$PWD/k3s.yaml
```

> 💡 **Tip:** give each cluster its own kubeconfig — `kind create cluster
> --kubeconfig ~/.kube/csilab.yaml`, then `export KUBECONFIG=~/.kube/csilab.yaml` —
> so a later `kubectl delete` cannot land on the other lab, or on some unrelated
> cluster you keep. That is how these lessons were recorded.

## Ceph or Longhorn?

| | Ceph (v1.20.7 / Tentacle v20.2.4) | Longhorn (v1.12.1) |
|---|---|---|
| Install | operator + CRDs + CSI operator + cluster CR; several GB of images | **one Helm chart** |
| What it gives you | block (RBD), shared filesystem (CephFS), object (RGW) | block, plus NFS re-export for RWX |
| Data path | kernel RBD client (`/dev/rbd0`), kernel CephFS | iSCSI login to an engine process, then `/dev/longhorn/<pvc>` |
| Replication unit | objects in placement groups (4MiB), spread by CRUSH | whole-volume replicas, one per node |
| Rebuild cost | only the missing objects move | a full replica is rebuilt |
| Failure domains | host, zone, rack — configurable per pool | nodes only |
| RWX | yes, CephFS, no extra component | yes, through a per-volume NFS `share-manager` pod |
| Snapshots | CSI `VolumeSnapshot` (verified in the Ceph lab) | native `Snapshot` CRs; CSI snapshots need explicit enablement |
| Backups | S3/NFS via the CSI snapshotter | S3/NFS via `Backup` + a configured backupstore |
| Minimum useful cluster | 3 nodes for `size: 3`; runs on 1 with `size: 1` | 3 nodes for 3 replicas; works on 1 |
| Operational weight | hours to learn, days to run well | minutes to learn, less to run |
| **In this course** | **on kind: block + RWX + expansion + snapshot/restore all verified** | **on two VMs: attach, replicas, cross-node durability, node loss and rebuild all verified** |

**Choose Longhorn** when storage should behave like the rest of your cluster: a
Helm chart, a DaemonSet, CRs you can read, replicas you can count per node, and no
career in Ceph. It is the right default for a platform team that wants replicated
storage without a storage team.

**Choose Ceph** when you need shared filesystems and object storage from the same
system, placement rules finer than "one copy per node", a data path with no
userspace daemon in it, or an ecosystem (RBD mirroring, CephFS, RGW, erasure
coding) that Longhorn does not have. You are buying capability with operational
complexity.

**Do not choose either** because "storage is hard" — a single-node `local-path`
claim fails loudly and early; silent replication you do not understand fails during
an incident. Pick the one whose failure modes you have seen.

## Cleanup

```bash
./cleanup.sh                 # both labs, checking what exists first
./cleanup.sh ceph            # only the Ceph lab
./cleanup.sh longhorn        # only the Longhorn lab
KEEP_CLUSTERS=1 ./cleanup.sh # uninstall the storage systems, keep the nodes
```

It is idempotent and skips anything that is not there, and it detaches the loop
devices **before** deleting a cluster: deleting a kind node while a loop device is
attached to a file inside it leaves the host kernel holding a device whose backing
file no longer exists.

## Is this production?

The drivers, the CRDs, the StorageClasses and the failure modes are the real ones.
Three honest caveats, each developed in the lessons:

- **The disks are loop devices.** They cannot fail like disks, and every
  throughput number you could measure is meaningless. The course publishes none.
- **Longhorn does not officially support kind, so its lab does not use it.** The
  short reason: Longhorn resolves its data path to the filesystem underneath it, and
  inside a kind node that resolution lands on the host's btrfs with zero bytes free,
  so no replica is ever scheduled. [Lesson 01](longhorn-lab/01-longhorn/README.md)
  has the full investigation — along with two explanations this course got wrong
  first, which is the more useful part to read.
- **Your real disk is visible to Rook.** A privileged kind node exposes the host's
  device nodes, so OSD discovery inventories your actual NVMe. The Ceph lab names
  one device per node precisely so that cannot matter; `useAllDevices: true` on a
  machine whose disk looked empty would have wiped it.

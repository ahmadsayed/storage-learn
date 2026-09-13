# The Ceph lab — Rook Ceph on its own kind cluster

Ceph is the heavyweight option: a real distributed storage system with a
replication policy you can reason about, at the cost of an operator, several
daemons and a licence to think about placement groups.

This lab has **its own kind cluster** (`csilab`), separate from the Longhorn lab.
That is deliberate: Ceph wants an empty block device per storage node, Longhorn
wants a directory with space, and the two fail in completely different ways.
Running them on one cluster would hide exactly what makes each of them worth
learning. `../../cleanup.sh` removes whichever lab's cluster exists.

## The lessons (run them in order)

| # | Lesson | What you do |
|---|--------|-------------|
| **00** | [The Ceph lab cluster](00-cluster-setup/README.md) | kind + two fake disks, udev, a writable `/sys`, and `/dev/rbd*` |
| **01** | [Rook Ceph: block storage and a shared filesystem](01-rook-ceph/README.md) | operator, 2 OSDs on 2 nodes, `HEALTH_OK`, a volume as `/dev/rbd0`, RWX from CephFS |
| **02** | [Day-2 operations](02-day2/README.md) | online expansion, CSI snapshot and restore, killing a storage node, serving reads while degraded |

The shared lesson [CSI fundamentals](../00-csi-fundamentals/README.md) is worth
running first if you have not met PV/PVC/StorageClass in anger; it runs on this
lab's cluster and installs the snapshot API that Lesson 02 uses.

## Requirements

| Tool | Why |
|------|-----|
| **Docker** + ~4GB of RAM free | each kind "node" is a container; Ceph adds a monitor, a manager, two OSDs and the CSI plugin pods |
| **kind** ≥ v0.31, **kubectl**, **git**, **Internet access** | the cluster, and about 1GB of Ceph images |
| **A disposable machine** | Rook's OSD discovery gets access to device nodes; this lab fences it by naming one device per node, but see Lesson 01 |

No GPU is needed. Linux is assumed (the lab reaches into Docker).

## How to run it

```bash
cd 00-cluster-setup
kind create cluster --config kind-config.yaml
./prepare-disks.sh
```

Then work through the lessons in order. Each one cleans up after itself, and
`../../cleanup.sh` tears the whole lab down — detaching the loop devices **before**
deleting the cluster, because deleting a kind node while a loop device is attached
to a file inside it leaves the host kernel holding a device whose backing file no
longer exists.

## What you end up with

| StorageClass | Provisioner | Access modes | Backed by | Survives a node dying |
|--------------|-------------|--------------|-----------|-----------------------|
| `rook-ceph-block` | `rook-ceph.rbd.csi.ceph.com` | RWO | an RBD image, 2 copies on 2 OSDs across 2 hosts | **yes, verified** — Lesson 02 reads a volume with half its replicas gone |
| `rook-cephfs` | `rook-ceph.cephfs.csi.ceph.com` | RWX | CephFS, 2 copies, one filesystem many pods mount | yes (same pools) |

## Is this production?

The mechanisms are real — Rook v1.20.7 with Ceph Tentacle v20.2.4 on Kubernetes
v1.35.0: same CRDs, same CSI driver, same failure modes. Three honest caveats,
each developed in the lessons:

- **The disks are loop devices.** They cannot fail like disks, and any throughput
  number from this lab is meaningless. The course publishes none.
- **Two OSDs is the smallest interesting Ceph.** `failureDomain: host` with
  `size: 2` gives a genuine cross-node story and a genuine degradation drill; it
  does not give you a rack, a zone, or a maintenance window.
- **Your real disk is visible to Rook.** A privileged kind node exposes the host's
  device nodes, so OSD discovery inventories your actual NVMe before skipping it.
  Naming one device per node is what keeps that from mattering — Lesson 01 shows
  the log line.

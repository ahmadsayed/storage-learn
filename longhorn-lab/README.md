# The Longhorn lab — one Helm chart, and one wall

Longhorn is the pragmatic answer to "I want replicated storage without running
Ceph": one chart, a DaemonSet, and volumes made of one independent copy per node.
It is also the system that teaches the most interesting lesson in this
repository — not because it works, but because of *where* it stops working and why.

This lab has **its own kind cluster** (`lhslab`), separate from the Ceph lab. That
separation is deliberate: Longhorn wants a directory with space where Ceph wants an
empty block device, and its data path is an iSCSI login through a userspace daemon
where Ceph's is the kernel RBD client. `../../cleanup.sh` removes whichever lab's
cluster exists.

## The lessons (run them in order)

| # | Lesson | What you do |
|---|--------|-------------|
| **00** | [The Longhorn lab cluster](00-cluster-setup/README.md) | kind + a data path per node + an `iscsid` you have to start correctly |
| **01** | [Longhorn](01-longhorn/README.md) | install, disks, **three replicas on three nodes** — and the proof of why the V1 data engine cannot attach a volume on kind |

## What this lab honestly delivers

| | Status |
|---|---|
| Install (one Helm chart), nodes, disks, StorageClasses | **works, verified** |
| Volume provisioning and replica placement: 3 replicas on 3 different nodes | **works, verified** |
| Replica and node state when a node is stopped | **works, verified** |
| Attaching a volume so a pod can mount it | **does not work on kind** — and Lesson 01 proves why (namespaces + the iscsid client protocol), rather than blaming the loop devices |

That last row is the point. Every Longhorn tutorial assumes a normal node; this lab
shows what actually happens when the node is a container, with the daemon's own
error messages and the namespace IDs that explain them. If you take one thing from
this lab, take the diagnostic method.

## Requirements

| Tool | Why |
|------|-----|
| **Docker** + ~3GB of RAM free | each kind "node" is a container; Longhorn adds a manager, an instance manager and CSI pods on every node |
| **kind** ≥ v0.31, **kubectl**, **helm** ≥ v3.13 | the cluster and the chart |
| **Internet access** | the node image and Longhorn's images (~500MB) |
| **A disposable machine** | the lab's nodes are privileged containers that load kernel modules |

## How to run it

```bash
cd 00-cluster-setup
kind create cluster --config kind-config.yaml
./prepare-disks.sh     # data path per node + iscsid, and it reports what it got

cd ../01-longhorn
kubectl label node lhslab-control-plane lhslab-worker lhslab-worker2 \
  node.longhorn.io/create-default-disk=true --overwrite
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
  --version 1.12.1 -f values.yaml
```

## Cleanup

```bash
../../cleanup.sh longhorn     # just this lab
../../cleanup.sh              # both labs
```

Longhorn refuses to uninstall until `deleting-confirmation-flag` is set, and the
script handles that as well as detaching the loop devices before the cluster is
deleted.

# Lesson 01 — Longhorn: replicated volumes that a pod can actually mount

## Glossary

| Term | What it means |
|------|---------------|
| **Longhorn** | a distributed block-storage system built for Kubernetes, installed as one Helm chart |
| **longhorn-manager** | the control plane: a DaemonSet, one pod per node, that reconciles volumes, replicas and disks |
| **instance-manager** | the data plane: one pod per node that runs the engine and replica processes of the volumes attached there |
| **engine** | the process that serves a volume: it fans writes out to every replica and exposes the volume to its node |
| **replica** | one complete copy of a volume's data, stored as a sparse file on one node's data path |
| **frontend (iSCSI)** | how the V1 engine exposes a volume to its node: an iSCSI target the node logs into, giving `/dev/longhorn/<pvc>` |
| **share-manager** | a pod that re-exports a volume over NFS so several nodes can mount it (RWX) |
| **`Volume` / `Replica` / `Engine` CRs** | Longhorn's own resources (`lhv` / `lhr` / `lhe`); the UI and the CLI are views of these |
| **robustness** | `healthy`, `degraded` (a replica is missing but I/O works), `faulted` (no engine, nothing serving) |

This lesson installs Longhorn on the lab's two VMs and holds it to the four
promises that matter: a pod can mount a volume, the data outlives the pod's node,
the cluster keeps serving when a node dies, and the missing copy comes back when
that node returns. All four are demonstrated below with the machine's own output.

## Files

- `values.yaml` — the install: pinned chart version plus every lab-sized override, each commented.
- `namespace.yaml`, `pvc.yaml`, `pod-writer.yaml` — a 2Gi claim, and a pod that writes into it on `k3s-agent`.
- `pod-reader-other-node.yaml` — reads the same claim from `k3s-server`: the durability proof.
- `pod-during-failure.yaml` — writes to the volume every 10 seconds (24 writes, about four minutes, then it exits), for the node-failure drill.

## Step 1 — Install Longhorn

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
  --version 1.12.1 -f values.yaml
```

Pinned to **Longhorn v1.12.1** (chart `1.12.1`), which documents Kubernetes ≥ v1.25.
The install settles at 14 pods, all running, and the shape of that list is
Longhorn's architecture:

> 💡 **Tip:** helm may print a handful of `Warning: unrecognized format "int64"`
> lines while creating the CRDs. That is a cosmetic bug in the chart's CRD schemas
> (a few `type: string` fields declare `format: int64`); the API server ignores
> the unknown format and accepts the CRDs anyway. It is not a failure.

| Pod | Count | What it is |
|-----|-------|-----------|
| `longhorn-manager-*` | 1 per node | the control plane |
| `instance-manager-*` | 1 per node | where engines and replicas actually run |
| `engine-image-ei-*` | 1 per node | the engine binary ships in its own image and is unpacked onto each node's data path |
| `longhorn-csi-plugin-*` | 1 per node | the CSI node plugin |
| `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter` | 1 each | the CSI sidecars, as ordinary Deployments |
| `longhorn-driver-deployer`, `longhorn-ui` | 1 each | one-shot driver setup, and the UI |

```console
$ kubectl -n longhorn-system get pods | wc -l
14
$ kubectl -n longhorn-system get pods | grep -c Running
14

$ kubectl get storageclass
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer false
longhorn (default)     driver.longhorn.io      Delete          Immediate           true
longhorn-static        driver.longhorn.io      Delete          Immediate           true
```

> 💡 **Tip:** there are now **two default StorageClasses**. `persistence.defaultClass`
> made `longhorn` a default, but k3s' bundled `local-path` still is one too. Kubernetes
> allows that, and a PVC with no `storageClassName` gets whichever default was created
> *most recently*. Remove the other if you keep Longhorn as the default:
> `kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class-`

## Step 2 — What Longhorn made of the nodes

```bash
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io k3s-server -o jsonpath='{.spec.disks}'
```

```console
$ kubectl -n longhorn-system get nodes.longhorn.io
NAME         READY   ALLOWSCHEDULING   SCHEDULABLE
k3s-agent    True    true              True
k3s-server   True    true              True

$ kubectl -n longhorn-system get nodes.longhorn.io k3s-server -o jsonpath='{.spec.disks}'
{"default-disk-9b69791540b0aa9c":{"allowScheduling":true,"diskDriver":"","diskType":"filesystem",
 "evictionRequested":false,"path":"/var/lib/longhorn","storageReserved":5904767385,"tags":[]}}
```

The disk was created for us — a generated name, `default-disk-<hash>`, because the
node carries the label from Lesson 00. And its accounting is *correct*:

```console
$ kubectl -n longhorn-system get nodes.longhorn.io k3s-server \
    -o jsonpath='{.status.diskStatus}' | grep -E 'filesystemType|storageMaximum|storageAvailable|storageScheduled'
"filesystemType": "ext2/ext3",          <- Longhorn's label for the ext family: this is the ext4 root
"storageAvailable": 13212057600,        <- 12.3 GiB free
"storageMaximum":  19682557952,         <- 18.3 GiB total
"storageScheduled": 2147483648,         <- 2 GiB of replicas already scheduled
```

(`storageScheduled` reads 2 GiB here because this capture was taken after Step 3's
volume existed; before the first volume it reads 0.)

`storageReserved` is 5.9GB, which is 30% of that 18.3GB — the chart default doing
arithmetic on real numbers. Compare that with the same three commands against a kind
node in the appendix at the end of this lesson, where every one of them reads zero
and the filesystem is reported as btrfs, the host's.

> 🎓 **Insight:** Longhorn does not just want a directory with space. It resolves the
> data path to the filesystem underneath it, and everything it can schedule follows
> from that answer. This is why the lab is on VMs.

## Step 3 — A volume a pod can actually mount

```bash
kubectl apply -f namespace.yaml -f pvc.yaml -f pod-writer.yaml
kubectl -n lh-demo get pvc
kubectl -n lh-demo logs lh-writer
```

```console
$ kubectl -n lh-demo get pvc
NAME     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
lh-pvc   Bound    pvc-41633c7b-3df6-4db6-87a4-ad3f18d9b1d8   2Gi        RWO            longhorn

$ kubectl -n lh-demo get pod lh-writer -o wide
NAME        READY   STATUS      NODE
lh-writer   0/1     Completed   k3s-agent

$ kubectl -n lh-demo logs lh-writer
written on lh-writer at 2026-09-13T08:27:35Z
                          1.9G     28.0K      1.9G   0% /data
```

A real filesystem at `/data`, on a volume Longhorn built. The Longhorn side of the
same moment:

```console
$ kubectl -n longhorn-system get volumes.longhorn.io
NAME                                       DATA ENGINE   STATE      ROBUSTNESS   SCHEDULED   SIZE         NODE
pvc-41633c7b-3df6-4db6-87a4-ad3f18d9b1d8   v1            attached   healthy                  2147483648   k3s-agent

$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState
NAME                                                  NODE         STATE
pvc-41633c7b-...-r-16bebce6                           k3s-agent    running
pvc-41633c7b-...-r-36a98a45                           k3s-server   running
```

`STATE: attached`, `ROBUSTNESS: healthy`, and **two replicas, one on each node** —
which is `defaultClassReplicaCount: 2` doing its job. The `volumeHandle` is `pvc-`
plus the claim's UID, so the link between Kubernetes and Longhorn is easy to follow.

> 🎓 **Insight:** anti-affinity was not something you had to enable. Longhorn
> defaults to `replicaSoftAntiAffinity: false`, meaning it refuses to put two healthy
> replicas of one volume on one node. That is why two nodes is the smallest cluster
> where a Longhorn volume has any redundancy at all.

## Step 4 — The data outlives the pod's node

The writer ran on `k3s-agent`. Delete it and run the reader on `k3s-server`:

```bash
kubectl -n lh-demo delete pod lh-writer
kubectl apply -f pod-reader-other-node.yaml
kubectl -n lh-demo logs lh-reader
```

```console
$ kubectl -n lh-demo logs lh-reader
reading on lh-reader:
written on lh-writer at 2026-09-13T08:27:35Z

$ kubectl -n lh-demo get pod lh-reader -o wide
NAME        READY   STATUS      NODE
lh-reader   0/1     Completed   k3s-server
```

While that happened, Longhorn detached the volume from one node and attached it to
the other, ending `attached/healthy` again — a pod on node B read a file written by
a pod on node A, with no copy step in between. This is the promise that a
single-node `local-path` volume cannot keep, and it is worth doing by hand once.

## Step 5 — Kill a node, and watch the volume keep serving

`pod-during-failure.yaml` writes to the volume every 10 seconds from the node we are
*not* going to kill, so the log records whether I/O survived the failure:

```bash
kubectl apply -f pod-during-failure.yaml          # writes on k3s-server
../00-cluster-setup/vm.sh ssh agent -- 'sudo poweroff'   # the node simply disappears
```

```console
$ kubectl get nodes
NAME         STATUS     ROLES           AGE     VERSION
k3s-agent    NotReady   <none>          9m3s    v1.36.4+k3s1
k3s-server   Ready      control-plane   10m     v1.36.4+k3s1

$ kubectl -n longhorn-system get volumes.longhorn.io
NAME                                       STATE      ROBUSTNESS   NODE
pvc-41633c7b-3df6-4db6-87a4-ad3f18d9b1d8   attached   degraded     k3s-server

$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState
NAME                                                  NODE         STATE
pvc-41633c7b-...-r-16bebce6                           k3s-agent    stopped
pvc-41633c7b-...-r-36a98a45                           k3s-server   running

$ kubectl -n lh-demo logs lh-continuous-writer | tail -8
write 17 at 2026-09-13T08:31:09Z from lh-continuous-writer
write 18 at 2026-09-13T08:31:19Z from lh-continuous-writer
write 19 at 2026-09-13T08:31:29Z from lh-continuous-writer
write 20 at 2026-09-13T08:31:39Z from lh-continuous-writer
write 21 at 2026-09-13T08:31:49Z from lh-continuous-writer
write 22 at 2026-09-13T08:31:59Z from lh-continuous-writer
write 23 at 2026-09-13T08:32:09Z from lh-continuous-writer
write 24 at 2026-09-13T08:32:19Z from lh-continuous-writer
```

Read those three outputs together, because together they are the entire argument for
replication:

| Output | What it means |
|--------|---------------|
| node `NotReady` | Kubernetes noticed, and stopped trusting the node |
| `ROBUSTNESS: degraded` | Longhorn noticed too, and says so in one word — **not** `faulted` |
| the replica on the dead node is `stopped`, the other `running` | one copy is gone; the volume is now one copy away from data loss |
| the writer logged writes 17–24 straight through the outage | **the pod never noticed.** I/O continued on the surviving replica |

> 🎓 **Insight:** `degraded` and `faulted` are the two words worth knowing. A
> `degraded` volume is serving with fewer copies than configured — you have time to
> act. A `faulted` volume has no working engine: that is the state you get with
> `numberOfReplicas: 1` and the wrong node gone.

## Step 6 — Bring the node back, and watch the copy return

```bash
../00-cluster-setup/vm.sh start agent   # the same VM, the same disk — a reboot, not a reinstall
kubectl -n lh-demo delete pod lh-continuous-writer --ignore-not-found   # it exited after write 24
kubectl apply -f pod-during-failure.yaml   # a fresh pod keeps the volume attached
```

(The delete matters: the writer has `restartPolicy: Never` and had already
completed, so re-applying the unchanged manifest would print `unchanged` and the
volume would stay detached.)

```console
$ kubectl -n longhorn-system get volumes.longhorn.io    # polled every 15s
  t=15s volume=detached/unknown    replicas: k3s-agent=stopped k3s-server=stopped
  t=30s volume=attached/degraded   replicas: k3s-agent=running k3s-server=running
  t=45s volume=attached/healthy    replicas: k3s-agent=running k3s-server=running
```

Both replicas come back and the volume reaches `healthy` within about 45 seconds of
the node being Ready again. Nothing was copied by hand, and nothing was lost: the
surviving replica held every byte the writer had written during the outage, and
Longhorn used it to bring the returning copy back in sync.

> ⚠️ **Warning — one detail to get right when you run this.** Longhorn only reports
> `robustness` while a volume is **attached**. If the pod holding the volume exits
> during the drill, the volume detaches and `robustness` reads `unknown`, which looks
> like a failure and is not. Keep a pod on the volume for the whole drill — that is
> what `pod-during-failure.yaml` is for. Note that it stops after 24 writes (about
> four minutes): if your drill runs longer, delete and re-apply it as Step 6 does.

## Appendix — why this lab is not on kind

The first version of this lab ran on a three-node kind cluster, because that is what
the Ceph lab uses. Everything on Longhorn's control plane worked there: install,
disks, nodes, and **three replicas placed on three different nodes**. The volume never
attached, and getting to the bottom of it took longer than it should have. The short
version:

| Symptom | What it looked like |
|---------|--------------------|
| The pod stuck in `ContainerCreating` | `AttachVolume.Attach failed … waiting for the volume to fully detach` |
| The volume | `attaching` → `detaching` → `faulted`, forever |
| The replicas | created one per node, then `stopped` — never `running` |
| The engine's log | `Failed to startup frontend … could not communicate to iscsid` |
| **The disk** | `"filesystemType": "btrfs"`, `"diskName": "/dev/nvme0"`, `"storageMaximum": 0`, `"storageAvailable": 0` |

That last row is the cause. Longhorn resolves the data path to the filesystem
*underneath* it; inside a kind node `/var/lib/longhorn` is an ext4 loop mount whose
mount entry is not visible to the manager's namespace, so the resolution landed on the
host's btrfs filesystem — with zero bytes free. **A disk with no space schedules no
replicas**, so no engine could start and the volume could only ever be `faulted`. On
the VM cluster the same three commands report ext4, 18.3GB and 12.3GB available.

Two things this course got wrong on the way, recorded because the reasoning matters
more than the answer:

- **It blamed the iSCSI path first.** Longhorn runs `iscsiadm` inside a live `iscsid`
  process's namespaces (`nsenter --mount=… --net=…`, with no `--pid`), and the
  namespace IDs really were different from the node's. That looked conclusive. It was
  not: the same invocation was later shown to work — `iscsiadm -m session` answered
  cleanly from inside the pod — once `iscsid` was running as a daemon that owned the
  control socket instead of fighting systemd's socket unit for it. The namespaces were
  a red herring.
- **It then blamed the daemon's lifecycle.** In a kind node `iscsid` is socket
  activated and exits when idle, so the PID Longhorn caches can be dead by its next
  call. That does happen, and it produces a *different* error (`daemon died?`). It was
  never the blocker either, because the volume failed identically while the daemon was
  alive.

None of which changes the practical conclusion, because Longhorn does not support
kind: it is absent from the project's platform list and from its CI, and a maintainer
has said plainly that container-in-container environments are the problem. **If you
want Longhorn, give it real nodes** — VMs count, as this lab shows.

## Production note

- **Two replicas is the minimum, not the target.** With two nodes, one node down
  leaves exactly one copy and no ability to rebuild until it returns. Three or more
  storage nodes is where Longhorn's anti-affinity gets useful.
- **Every replica is a full copy.** Longhorn replicates whole volumes, so a 100GB
  volume with 2 replicas uses 200GB plus snapshot space. Ceph replicates 4MiB objects
  instead and rebuilds only what is missing.
- **Set `node-down-pod-deletion-policy`** (`delete-deployment-pod` or
  `delete-both-statefulset-and-deployment-pod`) if you want workloads stranded on a
  dead node to move. The default, `do-nothing`, leaves them waiting because their RWO
  volume is still attached to the node that is gone.
- **Snapshots are not backups.** Longhorn snapshots live inside the volume's own
  disks; `Backup` needs an NFS or S3 backupstore configured
  (`defaultBackupStore.backupTarget`), and a snapshot on the same disk as its volume
  is not even a snapshot.
- **RWX goes through a `share-manager` pod** that re-exports the volume over NFS, so
  every node that mounts it needs an NFS client. Lesson 00 installs one, which is why
  RWX works here without extra steps.

## Next

That is the Longhorn lab. The Ceph lab makes the same promises with a different data
path — no userspace daemon at all — and compares the two honestly:
[the Ceph lab](../../ceph-lab/README.md). To remove this lab,
`../00-cluster-setup/vm.sh destroy` (or `../../cleanup.sh longhorn`, which does that
for you).

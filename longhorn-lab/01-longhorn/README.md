# Lesson 01 — Longhorn: three replicas on three nodes, and the wall

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
| **SCM_CREDENTIALS** | how a unix-socket server learns *which process* is calling it — and the reason this lesson's failure happens |

This lesson installs Longhorn, shows that it really does place **three replicas on
three different nodes**, and then documents — with the daemon's own error messages
and the namespace IDs behind them — why its V1 data engine cannot attach a volume
inside a kind node. The provisioning half is a real demonstration; the second half
is a diagnosis, and it is the more useful of the two.

## Files

- `values.yaml` — the install: pinned chart version plus every lab-sized override, each commented.
- `namespace.yaml`, `pvc.yaml`, `pod-writer.yaml` — a 2Gi claim and a pod that writes to it.
- `pod-reader-other-node.yaml` — the same claim from the *other* worker: the durability proof, had the attach worked.

## Step 1 — Install Longhorn

```bash
kubectl label node lhslab-control-plane lhslab-worker lhslab-worker2 \
  node.longhorn.io/create-default-disk=true --overwrite

helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
  --version 1.12.1 -f values.yaml
```

Pinned to **Longhorn v1.12.1** (chart `1.12.1`), which documents Kubernetes ≥ v1.25,
so v1.35 is inside the supported range. The labels matter because `values.yaml`
sets `createDefaultDiskLabeledNodes: true`: only nodes you label become storage
nodes, instead of Longhorn claiming a disk on every node it ever sees.

Everything non-default in `values.yaml` is a lab concession or a decision worth
understanding:

| Setting | Lab value | Why |
|---------|-----------|-----|
| `persistence.defaultClassReplicaCount` | `3` | three storage nodes, so three copies — the point of this lesson |
| `defaultSettings.createDefaultDiskLabeledNodes` | `true` | an explicit list of storage nodes beats "every node, forever" |
| `defaultSettings.storageMinimalAvailablePercentage` | `10` | our disks are 5GiB; at the 25% default a disk can become unschedulable after two small volumes |
| `defaultSettings.storageOverProvisioningPercentage` | `200` | lets the lab show thin provisioning: nominal capacity may exceed physical |
| `defaultSettings.guaranteedInstanceManagerCPU` | `{"v1":"5","v2":"5"}` | the 12% default reserves ~1.4 CPUs *per node* of this 12-CPU host |
| `csi.*ReplicaCount` | `1` each | four sidecars × 1 instead of × 3; ~8 pods of RAM saved. Set at install time — a later `helm upgrade` ignores them for existing deployments |
| `longhornUI.replicas` | `1` | the chart default is 2; nobody is on call for a lab |

The install settles at **18 pods, all running**:

| Pod | Count | What it is |
|-----|-------|-----------|
| `longhorn-manager-*` | 1 per node | the control plane |
| `instance-manager-*` | 1 per node | where engines and replicas actually run |
| `engine-image-ei-*` | 1 per node | the engine binary ships in its own image and is unpacked onto each node's data path |
| `longhorn-csi-plugin-*` | 1 per node | the CSI node plugin |
| `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter` | 1 each | the CSI sidecars, as ordinary Deployments |
| `longhorn-driver-deployer`, `longhorn-ui` | 1 each | one-shot driver setup, and the UI |

```console
$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION
longhorn (default)   driver.longhorn.io      Delete          Immediate           true
longhorn-static      driver.longhorn.io      Delete          Immediate           true
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer false
```

> 💡 **Tip:** there are now **two default StorageClasses**. `persistence.defaultClass`
> made `longhorn` a default, but kind's `standard` still is one too. Kubernetes
> allows that, and a PVC with no `storageClassName` gets whichever default was
> created *most recently* — a genuinely nasty surprise in a real cluster. Remove the
> other one if you keep Longhorn as the default:
> `kubectl annotate sc standard storageclass.kubernetes.io/is-default-class-`

## Step 2 — What Longhorn made of the nodes, and one thing it got wrong

```bash
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io lhslab-worker -o jsonpath='{.spec.disks}'
```

```console
$ kubectl -n longhorn-system get nodes.longhorn.io
NAME                   READY   ALLOWSCHEDULING   SCHEDULABLE
lhslab-control-plane   True    true              True
lhslab-worker          True    true              True
lhslab-worker2         True    true              True

$ kubectl -n longhorn-system get nodes.longhorn.io lhslab-worker -o jsonpath='{.spec.disks}'
{"default-disk-d555c32be30093d1":{"allowScheduling":true,"diskDriver":"","diskType":"filesystem",
 "evictionRequested":false,"path":"/var/lib/longhorn","storageReserved":112801087488,"tags":[]}}
```

The disk was **created for us** — with a generated name, `default-disk-<hash>` —
because the node carries the label we set and `createDefaultDiskLabeledNodes` is
true. Lesson 00 put ext4 on `/dev/loop221` at `/var/lib/longhorn`, and that mount
was not optional: Longhorn supports only extent-based filesystems, and this
workstation's root filesystem is btrfs.

Now look at what Longhorn believes about that disk:

```console
$ kubectl -n longhorn-system get nodes.longhorn.io lhslab-worker \
    -o jsonpath='{.status.diskStatus}' | grep -E 'filesystemType|diskName|storageMaximum|storageAvailable'
"filesystemType": "btrfs",          <- not the ext4 we mounted
"diskName": "/dev/nvme0",           <- the host's real disk, not /dev/loop221
"storageMaximum": 0,
"storageAvailable": 0,
```

The reservation gives it away: `112801087488` bytes is **105GiB**, which is about
30% of the host's 376GB filesystem — not 30% of a 5GiB device.

> ⚠️ **Warning, and an honest gap.** Longhorn's disk accounting here is reading the
> filesystem *underneath* our loop mount — the host's btrfs NVMe — rather than the
> ext4 created inside the node. The likely mechanism is that a mount made inside a
> node container is not visible as a *mount entry* to a pod's mount table, so the
> path resolves to its parent filesystem; the manager pod's own view is split, which
> is why `df` inside it reports `/dev/loop221` while `findmnt` says "not a mount
> point". I could not confirm that from Longhorn's source, so treat it as an
> observation, not a finding.
>
> Either way the practical consequence is concrete: **Longhorn's capacity numbers in
> this lab cannot be trusted** (`storageMaximum: 0`), and in a real cluster a data
> path that is a *bind mount* rather than its own filesystem is exactly the kind of
> thing that produces this. A real node mounts a real disk there.

## Step 3 — A volume, and three replicas on three different nodes

```bash
kubectl apply -f namespace.yaml -f pvc.yaml -f pod-writer.yaml
kubectl -n lh-demo get pvc lh-pvc
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState
```

```console
$ kubectl -n lh-demo get pvc lh-pvc
NAME     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
lh-pvc   Bound    pvc-ea0cc7aa-0f2b-43b2-ae2b-e2b844307a56   2Gi        RWO            longhorn

$ kubectl get pv pvc-ea0cc7aa-... -o custom-columns=DRIVER:.spec.csi.driver,HANDLE:.spec.csi.volumeHandle
DRIVER               HANDLE
driver.longhorn.io   pvc-ea0cc7aa-0f2b-43b2-ae2b-e2b844307a56

$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState
NAME                                                  NODE                   STATE
pvc-ea0cc7aa-...-r-8701d06f                           lhslab-control-plane   stopped
pvc-ea0cc7aa-...-r-a6b13bde                           lhslab-worker2         running
pvc-ea0cc7aa-...-r-cb1b2949                           lhslab-worker          running
```

That is Longhorn's promise, verified: one claim became a volume with **three
independent replicas, one per node, on three different disks** (`DISK` in the same
output shows three distinct disk UUIDs). Note that the `volumeHandle` is simply the
PVC's UID — unlike Ceph's `0001-0009-rook-ceph-<pool>-<uuid>`, Longhorn names volumes
after their claim, which makes the link between Kubernetes and the storage layer much
easier to follow.

> 🎓 **Insight:** anti-affinity is not something you had to enable. Longhorn
> defaults to `replicaSoftAntiAffinity: false`, so it refuses to put two healthy
> replicas of one volume on one node. Three nodes is therefore the smallest
> interesting Longhorn cluster — and the reason Lesson 00 had to untaint the
> control-plane node.

## Step 4 — The wall: the volume never attaches

```console
$ kubectl -n lh-demo get pod lh-writer
NAME        READY   STATUS              RESTARTS   AGE
lh-writer   0/1     ContainerCreating   0          3m

$ kubectl -n longhorn-system get volumes.longhorn.io
NAME                                       DATA ENGINE   STATE      ROBUSTNESS   SCHEDULED   SIZE
pvc-ea0cc7aa-0f2b-43b2-ae2b-e2b844307a56   v1            attaching  unknown                  2147483648

$ kubectl -n lh-demo describe pod lh-writer | tail -2
  Warning  FailedAttachVolume  AttachVolume.Attach failed ... volume ... is not ready for workloads:
           waiting for the volume to fully detach. current state: attaching
```

The volume cycles `attaching` → `detaching` → `faulted` for as long as you watch it.
Nothing is wrong with the replicas: two are `running`, and Longhorn is not confused
about the data. The **engine** never comes up, because it cannot log in to its own
iSCSI target. From the instance-manager's log:

```console
... nsenter [nsenter --mount=/host/proc/1226/ns/mnt --net=/host/proc/1226/ns/net iscsiadm
    -m node -T iqn.2019-10.io.longhorn:pvc-ea0cc7aa-... -o update ...], stderr
    iscsiadm: No records found: exit status 21

... Failed to startup frontend ... stderr
    iscsiadm: read error (0/2), daemon died?
    iscsiadm: initiator reported error (18 - could not communicate to iscsid)

... iscsiadm: can not connect to iSCSI daemon (111)!
```

## Step 5 — Why, exactly

Longhorn's V1 engine exposes a volume over iSCSI, and it runs `iscsiadm` like this:

```
nsenter --mount=/host/proc/<iscsid pid>/ns/mnt --net=/host/proc/<iscsid pid>/ns/net iscsiadm ...
```

It joins the node's **mount** and **network** namespaces — and note what is missing:
`--pid`. So compare three views of the same machine:

```console
--- A) the NODE (docker exec lhslab-worker) ---
  pid pid:[4026534032]     mnt mnt:[4026534029]     net net:[4026534034]
--- B) the instance-manager POD ---
  pid pid:[4026535535]     mnt mnt:[4026535462]     net net:[4026536314]
--- C) the ENGINE's iscsiadm (nsenter into the node's mount+net) ---
  pid pid:[4026535535]     mnt mnt:[4026534029]     net net:[4026534034]
```

- **C matches A** on `mnt` and `net`: the node's namespaces really were joined.
- **C matches B** on `pid`: the client asking for the login is still inside the
  **pod's** PID namespace, while `iscsid` lives in the node's.

`iscsid` authenticates its clients with `SCM_CREDENTIALS`, which carries the caller's
PID — a PID that means nothing in the daemon's own namespace. It drops the
connection, and the engine sees exactly that: `read error (0/2), daemon died?`.

Three further observations make the wall solid rather than unlucky:

| Observation | What it means |
|-------------|---------------|
| The same failure happens on this **dedicated** cluster, not only where Ceph also ran | it is not interference between two storage systems |
| It happens both on the node whose daemon **is** alive (`live iscsid processes: 2` in Lesson 00's output) and on the node where it has exited (`0`) | the PID namespace mismatch is structural; the daemon's lifecycle only changes which error you get |
| Lesson 00's per-node daemon counts differed (2, 0, 2) from one script and one image | the daemon is socket-activated and exits when idle, so the PID Longhorn caches can be dead by its next call — a second, aggravating failure |

> ⚠️ **Warning:** there is no setting for this. `iscsid` cannot be told to skip the
> peer check, and Longhorn does not expose the instance-manager's PID namespace. It
> is why **Longhorn does not support kind**: kind is absent from its platform list
> and from its CI, and a maintainer's answer in
> [discussion #2702](https://github.com/longhorn/longhorn/discussions/2702) is
> explicit that container-in-container environments are the problem. Historically
> the blocker was that the node image shipped no `open-iscsi` at all; kind fixed that
> in v0.20.0 and this lab's nodes have it — the remaining obstacle is the one above.

### Contrast with the Ceph lab

Ceph's data path needs **no userspace daemon**: the CSI node plugin asks the kernel to
map an RBD image and gets `/dev/rbd0`. That is the whole reason the Ceph lab's volume
attaches and this one does not, and it is a design difference worth carrying into any
storage decision — every daemon in the data path is another thing that must agree
about namespaces, permissions and lifecycle.

## Step 6 — What still holds, and how to run Longhorn for real

Everything on the control plane is real and verified here:

- Longhorn provisioned the volume and **placed three replicas across three nodes**;
  the anti-affinity rule, the disk CR, and the per-replica `spec.nodeID` /
  `spec.diskID` are not simulated.
- Longhorn's node CR reports node health honestly — `READY False` within a minute of
  a node being stopped — and replicas on a lost node go `stopped`.
- The `Replica` CRs answer "where are my three copies" with one `kubectl get`.

| If you want to run Longhorn for real | What it takes |
|--------------------------------------|---------------|
| **A VM-backed cluster** (minikube with the kvm/docker driver, k3s in a VM, Rancher Desktop, or real nodes) | a real kernel and a real PID namespace per node: iSCSI behaves normally and none of Step 5 happens |
| **Longhorn's V2 data engine** (NVMe-oF instead of iSCSI) | 2GiB of 2MiB hugepages per node, `vfio-pci`/`uio_pci_generic`, block-type disks, and a dedicated CPU per instance manager — possible on this host's kernel, out of scope for a three-node lab |
| **kind** | the control plane works (this lesson); the V1 data plane cannot attach |

## Production note

- **Three replicas cost three times the writes and three times the space.** Ceph
  replicates 4MiB objects and rebuilds only what is missing; Longhorn rebuilds a whole
  replica.
- **`replicaSoftAntiAffinity: false` is a placement promise that needs nodes to keep
  it.** With three storage nodes, one node down means the third replica cannot be
  recreated anywhere until it returns.
- **Set `node-down-pod-deletion-policy`** (`delete-deployment-pod` or
  `delete-both-statefulset-and-deployment-pod`) if you want workloads on a dead node
  to move. The default, `do-nothing`, leaves the pod stuck because its RWO volume is
  still attached to the lost node.
- **Snapshots are not backups.** Longhorn snapshots are local; a `Backup` needs an
  NFS or S3 backupstore (`defaultBackupStore.backupTarget`), and a snapshot on the
  same disk as its volume is not even a snapshot.
- **The data path should be its own filesystem, not a bind mount.** This lab's
  capacity accounting (Step 2) is the cautionary tale.

## Next

That is the Longhorn lab. The Ceph lab makes the same three promises —
provisioning, replication, and a node dying — with a data path that has no daemon in
it: [the Ceph lab](../../ceph-lab/README.md). To remove this one,
`../../cleanup.sh longhorn`.

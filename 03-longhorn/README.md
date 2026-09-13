# Lesson 03 — Longhorn: replicated volumes, and the wall kind puts up

## Glossary

| Term | What it means |
|------|---------------|
| **Longhorn** | a lightweight distributed block-storage system built for Kubernetes, installed as one Helm chart |
| **longhorn-manager** | the control plane: a DaemonSet, one per node, that reconciles volumes, replicas and disks |
| **instance-manager** | the data plane: one pod per node that runs the engine and replica processes of the volumes attached there |
| **engine** | the process that serves a volume: it fans writes out to every replica and presents the volume to the node |
| **replica** | one full copy of a volume's data, stored as a sparse file on one node's disk |
| **frontend (iSCSI)** | how the V1 engine exposes a volume to its node: an iSCSI target the node logs into, giving `/dev/longhorn/<pvc>` |
| **share-manager** | a pod that re-exports a volume over NFS so several nodes can mount it (RWX) |
| **`Volume` / `Replica` / `Engine` CRs** | Longhorn's own resources (`lhv` / `lhr` / `lhe`) — the UI and the CLI are both just views of these |
| **data path** | the directory Longhorn stores replicas in: `/var/lib/longhorn` by default |
| **robustness** | `healthy`, `degraded` (a replica is missing but I/O works), `faulted` (no engine, nothing serving) |
| **node-down pod deletion policy** | what Longhorn does to the *workload* when a node dies — `do-nothing` by default |

Longhorn is the pragmatic answer to "I want replicated storage without running
Ceph": one chart, a DaemonSet, and volumes made of one independent copy per node.
This lesson installs it, shows that the replicas really do land on three
different nodes, and then runs into the one wall this lab cannot climb — with the
evidence, because a storage course that hides a failure is not worth reading.

## Files

- `values.yaml` — the install: pinned chart version plus every lab-sized override, each commented.
- `namespace.yaml`, `pvc.yaml`, `pod-writer.yaml` — a 2Gi claim and a pod that writes to it.
- `pod-reader-other-node.yaml` — the same claim from the *other* worker; the durability proof, if the attach worked.

## Step 1 — Point Longhorn at the nodes, then install it

```bash
kubectl label node csilab-control-plane csilab-worker csilab-worker2 \
  node.longhorn.io/create-default-disk=true --overwrite

helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
  --version 1.12.1 -f values.yaml
```

Pinned to **Longhorn v1.12.1** (chart `1.12.1`), which documents Kubernetes ≥
v1.25 — so v1.35 is inside the supported range. The labels matter because
`values.yaml` sets `createDefaultDiskLabeledNodes: true`: only nodes you label
become storage nodes, instead of Longhorn claiming a disk on every node it ever
sees.

Everything non-default in `values.yaml` is either a lab concession or a decision
worth understanding:

| Setting | Lab value | Why |
|---------|-----------|-----|
| `persistence.defaultClassReplicaCount` | `3` | three storage nodes, so three copies — the point of the lesson |
| `defaultSettings.createDefaultDiskLabeledNodes` | `true` | an explicit list of storage nodes beats "every node, forever" |
| `defaultSettings.storageMinimalAvailablePercentage` | `10` | our disks are 5GiB; at the 25% default a disk becomes unschedulable after two small volumes |
| `defaultSettings.storageOverProvisioningPercentage` | `200` | lets the lab show thin provisioning: nominal capacity can exceed physical |
| `defaultSettings.guaranteedInstanceManagerCPU` | `{"v1":"5","v2":"5"}` | the 12% default reserves ~1.4 CPUs *per node* of this 12-CPU host |
| `csi.*ReplicaCount` | `1` each | 4 sidecars × 1 instead of × 3; ~8 pods of RAM saved. Must be set at install time — a later `helm upgrade` ignores them for existing deployments |
| `longhornUI.replicas` | `1` | chart default is 2; nobody is on call for a lab |

```console
$ kubectl -n longhorn-system get pods
NAME                                                READY   STATUS    RESTARTS
csi-attacher-6f9c7bc587-52pzm                       1/1     Running   0
csi-provisioner-7474bb8b7c-dvqfk                    1/1     Running   0
csi-resizer-5974b8575-t6dbb                         1/1     Running   0
csi-snapshotter-79886fb865-zgwd2                    1/1     Running   0
engine-image-ei-493e04e7-fv5gb                      1/1     Running   0
engine-image-ei-493e04e7-mskjn                      1/1     Running   0
engine-image-ei-493e04e7-vtf6s                      1/1     Running   0
instance-manager-0915f2a67bdd25de6c2ed5fae0b8db91   1/1     Running   0
instance-manager-89de96d059a91d9d9a6fbc5cfd0aa444   1/1     Running   0
instance-manager-a481163ec6a198b67569559999391df7   1/1     Running   0
longhorn-csi-plugin-9jdzh                           3/3     Running   0
longhorn-csi-plugin-m95zd                           2/3     Running   0
longhorn-csi-plugin-zrxmp                           2/3     Running   0
longhorn-driver-deployer-56d579fcb7-vbpbq           1/1     Running   0
longhorn-manager-bnc98                              2/2     Running   1 (97s ago)
longhorn-manager-jzj67                              2/2     Running   0
longhorn-manager-spvvm                              2/2     Running   0
longhorn-ui-5c57867c58-sgmh8                        1/1     Running   0
```

Read the shape of that list, because it is Longhorn's architecture:

- `longhorn-manager` — 3 pods, one per node: the control plane.
- `instance-manager` — 3 pods, one per node: where engines and replicas actually run.
- `engine-image` — 3 pods: the engine binary is shipped in its own image and unpacked onto each node's data path.
- `longhorn-csi-plugin` — the node plugin, plus the four CSI sidecars as ordinary Deployments.

## Step 2 — What Longhorn made of the nodes

```bash
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io csilab-worker \
  -o jsonpath='{.spec.disks}'
```

```console
$ kubectl -n longhorn-system get nodes.longhorn.io
NAME                   READY   ALLOWSCHEDULING   SCHEDULABLE   AGE
csilab-control-plane   True    true              True          102s
csilab-worker          True    true              True          102s
csilab-worker2         True    true              True          102s

$ kubectl -n longhorn-system get nodes.longhorn.io csilab-worker -o jsonpath='{.spec.disks}'
{"default-disk-6584b9e1903fc516":{"allowScheduling":true,"diskDriver":"","diskType":"filesystem",
 "evictionRequested":false,"path":"/var/lib/longhorn","storageReserved":1558914662,"tags":[]}}
```

The disk was **created for us** — with a generated name, `default-disk-<hash>` —
because the node carries the label we set and `createDefaultDiskLabeledNodes` is
true. Lesson 00 mounted `/var/lib/longhorn` as ext4 on a loop device, and
Longhorn accepted it; that mount was not optional. Longhorn only supports
extent-based filesystems, and this workstation's root filesystem is btrfs, so a
plain directory would have been rejected.

Two more things worth noticing before any volume exists:

```console
$ kubectl get storageclass
NAME                 PROVISIONER                     ...  ALLOWVOLUMEEXPANSION
longhorn (default)   driver.longhorn.io              ...  true
longhorn-static      driver.longhorn.io              ...  true
standard (default)   rancher.io/local-path           ...  false

$ kubectl get csinodes
NAME                   DRIVERS
csilab-control-plane   3
csilab-worker          4
csilab-worker2         3
```

- **There are now two default StorageClasses.** `persistence.defaultClass: true`
  made `longhorn` a default, but kind's `standard` still is one too. Kubernetes
  allows that, and a PVC with no `storageClassName` gets whichever default was
  created *most recently* — a genuinely nasty surprise in a real cluster. If you
  keep Longhorn as the default, remove the other:
  `kubectl annotate sc standard storageclass.kubernetes.io/is-default-class-`
- **`csilab-worker` has 4 CSI drivers registered** (hostpath, rbd, cephfs,
  longhorn) and the other nodes have 3. Multiple drivers coexist happily —
  that is the entire point of the CSI indirection from Lesson 01. The asymmetry
  is the hostpath *reference* driver from Lesson 01, which registered only on its
  own node.

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
lh-pvc   Bound    pvc-23131388-fd7b-4e8b-b5c0-b57c725a520c   2Gi        RWO            longhorn

$ kubectl get pv pvc-23131388-... -o custom-columns=DRIVER:.spec.csi.driver,HANDLE:.spec.csi.volumeHandle
DRIVER               HANDLE
driver.longhorn.io   pvc-23131388-fd7b-4e8b-b5c0-b57c725a520c

$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState
NAME                                                  NODE                   STATE
pvc-23131388-...-r-ab97575d                           csilab-worker          running
pvc-23131388-...-r-ccd6fd5f                           csilab-worker2         running
pvc-23131388-...-r-d7390460                           csilab-control-plane   running
```

That is the whole promise of Longhorn, verified: one claim became a volume with
**three independent replicas, one per node, on three different disks**
(`DISK` in the same output shows three distinct disk UUIDs). Note that the
`volumeHandle` is simply the PVC's UID — unlike Ceph's
`0001-0009-rook-ceph-<pool>-<uuid>`, Longhorn's volumes are named after their
claim, which makes the connection between Kubernetes and the storage layer much
easier to follow.

> 🎓 **Insight:** anti-affinity is not a setting you had to enable. Longhorn
> defaults to `replicaSoftAntiAffinity: false`, meaning it will *refuse* to put
> two healthy replicas of one volume on the same node. That is why three nodes is
> the smallest interesting Longhorn cluster, and why Lesson 00 untainted the
> control-plane node — otherwise only two nodes could host replicas and a
> three-replica volume would sit `degraded` forever.

## Step 4 — The wall: on kind, the engine cannot attach

The pod never starts:

```console
$ kubectl -n lh-demo get pod lh-writer
NAME        READY   STATUS              RESTARTS   AGE
lh-writer   0/1     ContainerCreating   0          8m2s

$ kubectl -n lh-demo describe pod lh-writer | tail -4
  Warning  FailedAttachVolume  AttachVolume.Attach failed ... volume pvc-5ad854d5-... is not ready
           for workloads: waiting for the volume to fully detach. current state: detaching
  Warning  FailedAttachVolume  AttachVolume.Attach failed ... failed to attach to node csilab-worker
           with attachmentID csi-8d35fd8b...
  Warning  FailedAttachVolume  AttachVolume.Attach failed ... volume is faulted

$ kubectl -n longhorn-system get volumes.longhorn.io
NAME                                       DATA ENGINE   STATE      ROBUSTNESS   SCHEDULED   SIZE
pvc-5ad854d5-37a6-47a8-86f2-65a6b5b9616e   v1            detached   faulted                  2147483648
```

The volume goes round the houses — `attaching` → `detaching` → `faulted` — while
all three replicas exist and are `stopped`. Nothing is wrong with the replicas.
The engine never comes up, because it cannot log in to its own iSCSI target:

```console
$ kubectl -n longhorn-system logs <instance-manager> -c instance-manager | grep 'Failed to discover'
... nsenter [nsenter --mount=/host/proc/<pid>/ns/mnt --net=/host/proc/<pid>/ns/net iscsiadm
    -m discovery -t sendtargets -p 10.244.2.20], stderr
      iscsiadm: can not connect to iSCSI daemon (111)!
      iscsiadm: Cannot perform discovery. Initiatorname required.
      iscsiadm: Could not perform SendTargets discovery: could not connect to iscsid: exit status 20
```

### Why, exactly

Longhorn's V1 engine exposes a volume over **iSCSI**, and it does two unusual
things:

1. it runs `iscsiadm` **inside the node's namespaces**, by entering
   `/host/proc/<iscsid pid>/ns/mnt` and `/ns/net` — it borrows a live `iscsid`
   process's mount and network namespaces;
2. it needs `iscsiadm` to talk to the `iscsid` **daemon** over the abstract unix
   socket `@ISCSIADM_ABSTRACT_NAMESPACE`.

Inside a kind node (a privileged container with its own PID namespace), those two
requirements cannot both be satisfied. There are exactly two states, and both
fail:

| State | What you see | Why it fails |
|-------|--------------|--------------|
| `iscsid` starts and owns the socket | `ss -xlp` shows `@ISCSIADM_ABSTRACT_NAMESPACE` owned by `iscsid` | the daemon's control-channel handshake breaks across the container's PID namespace — its log says `sendmsg: bug? ctrl_fd 5`, and clients get `can not connect to iSCSI daemon (111)` |
| systemd's `iscsid.socket` unit owns the socket | `ss -xlp` shows it owned by `systemd`; `iscsiadm` works from the node **and** from the instance-manager's namespace | but `iscsid` cannot bind, so it exits immediately, and Longhorn has no live process to borrow namespaces from — its cached PID dies and every later call reports `iscsiadm: read error (0/2), daemon died?` |

Both are demonstrated in the captured transcript of this run. The second state is
worth looking at closely, because it is the more confusing one:

```console
$ docker exec csilab-worker sh -c 'ss -xlp | grep ISCSIADM; pgrep -ax iscsid'
u_str LISTEN 0 4096 @ISCSIADM_ABSTRACT_NAMESPACE ... users:(("systemd",pid=1,fd=68))
iscsid processes:

$ docker exec csilab-worker sh -c 'systemctl start iscsid; sleep 3; pgrep -ax iscsid; sleep 5; pgrep -ax iscsid'
3s: /sbin/iscsid /sbin/iscsid      <- it starts...
8s:                                <- ...and is gone five seconds later

$ journalctl -u iscsid | tail -2
iscsid[81419]: iSCSI daemon with pid=81420 started!
iscsid[81419]: sendmsg: bug? ctrl_fd 5
```

> ⚠️ **Warning:** this is not a misconfiguration you can fix with a flag. It is the
> reason **Longhorn does not support kind** — it is absent from their platform
> list and from their CI, and a maintainer's answer in
> [discussion #2702](https://github.com/longhorn/longhorn/discussions/2702) is
> explicit that container-in-container environments are the problem ("the problem
> is `iscsi` can't run successfully inside the KIND… environment"). The historical
> blocker used to be that the node image had no `open-iscsi` at all; kind fixed
> that in v0.20.0, and this lab's nodes do have it — the remaining obstacle is the
> namespace/pID boundary above.
>
> Note what this says about the rest of the course: Ceph's data path (kernel RBD)
> needs no userspace daemon, which is exactly why Lesson 02 works where this one
> does not.

### What still holds

Everything on the control plane is real and verified on this cluster:

- Longhorn provisioned the volume and **placed three running replicas on three
  different nodes** — the placement logic, the anti-affinity rule and the disk CR
  are not simulated.
- When the node is later stopped (Lesson 04), the `Volume` and `Replica` CRs
  report it honestly: replicas on the stopped node go `failed`, robustness turns
  `degraded` — no engine, no data path, and Longhorn says so rather than guessing.
- The `Replica` CRs record `spec.nodeID` and `spec.diskID`, so "where are my three
  copies" is always answerable with one `kubectl get`.

## How to actually run Longhorn

| Option | What it takes |
|--------|---------------|
| **A VM-backed cluster** (minikube with the kvm/docker driver, k3s in a VM, Rancher Desktop, or real nodes) | a real kernel and a real PID namespace per node; iSCSI behaves normally and nothing in this lesson's Step 4 happens |
| **Longhorn's V2 data engine** (NVMe-oF instead of iSCSI) | 2GiB of 2MiB hugepages per node, `vfio-pci`/`uio_pci_generic`, block-type disks, and a dedicated CPU per instance manager — possible on the host kernel here, out of scope for a three-node lab |
| **kind** | the control plane works (this lesson), the data plane does not |

> 💡 **Tip:** if you are evaluating Longhorn for real, do it on the smallest
> cluster you can make with *real nodes* or VMs. The failure above is invisible in
> every tutorial that assumes a normal node, and it is not the sort of thing you
> want to discover while a database is waiting for its volume.

## Production note

- **Three replicas cost three times the writes and three times the space.** That
  is the trade against Ceph's object-level replication, where a 4MiB object is
  replicated rather than a whole volume, and rebuilding only moves what is
  missing. Longhorn rebuilds a full replica.
- **`replicaSoftAntiAffinity: false` is a placement promise that needs nodes to
  keep it.** With three storage nodes, one node down means the third replica
  cannot be recreated anywhere until it returns.
- **Set `node-down-pod-deletion-policy`** (`delete-deployment-pod` or
  `delete-both-statefulset-and-deployment-pod`) if you want workloads on a dead
  node to be able to move. The default, `do-nothing`, leaves the pod stuck
  because its RWO volume is still attached to the lost node.
- **Backups need a target.** Longhorn snapshots are local; a `Backup` needs an
  NFS or S3 backupstore (`defaultBackupStore.backupTarget`). Snapshots are not
  backups, and a snapshot on the same disk as its volume is not even a snapshot.
- **The UI is a Deployment, and its replica count is a chart default of 2.** It
  is also, for several operations — snapshot revert among them, which has no
  declarative form in the CRDs — the only supported way to do them.

## Next

Continue to [Lesson 04 — Day-2 operations, and choosing between them](../04-day2-and-comparison/README.md).

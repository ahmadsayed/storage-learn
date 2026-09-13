# Lesson 04 — Day-2 operations, and choosing between them

## Glossary

| Term | What it means |
|------|---------------|
| **day-2** | everything after "it works": growth, snapshots, failures, upgrades |
| **online expansion** | growing a volume while a pod is using it |
| **`FileSystemResizePending`** | "the device is bigger, the filesystem is not — restart a pod to finish" |
| **`VolumeSnapshot` / `VolumeSnapshotContent`** | the request and the thing the driver made, exactly like PVC/PV |
| **restore** | creating a *new* volume from a snapshot (the original is untouched) |
| **backup** | a copy that survives losing the storage system; a snapshot is not one |
| **failure domain** | the blast radius of one failure: a disk, a host, a zone |
| **`min_size`** | how many replicas must still hold an object before Ceph refuses the write |
| **quorum** | a majority of monitors; without it Ceph stops answering |
| **degraded / undersized PG** | the pool is serving, but with fewer copies than it was configured for |
| **backfill** | Ceph copying objects to bring an OSD back to the replication factor |
| **`Unknown` pod** | a pod object whose node went away; the container is gone but the record lingers |

This lesson does what you actually do to a storage system after it is running:
grow a volume, snapshot it, restore it, and kill a node underneath it. Then it
puts Ceph and Longhorn side by side and says which one to pick, including where
this lab's evidence runs out.

## Files

- `pod-rbd-verify.yaml` — runs after the expansion; prints the filesystem size the pod sees *and* the file Lesson 02 wrote.
- `snapshotclass-rbd.yaml` — the `VolumeSnapshotClass` for Ceph RBD.
- `volumesnapshot-rbd.yaml` — a snapshot of the 4Gi RBD volume.
- `pvc-rbd-restored.yaml`, `pod-rbd-restored.yaml` — a new volume built from that snapshot, and a pod that reads it.

All four live in the `ceph-demo` namespace from Lesson 02, because a
`VolumeSnapshot` can only snapshot a claim in its own namespace.

## Step 1 — Grow a volume, and learn why it takes two steps

```bash
kubectl -n ceph-demo patch pvc rbd-pvc -p '{"spec":{"resources":{"requests":{"storage":"4Gi"}}}}'
kubectl -n ceph-demo get pvc rbd-pvc
```

The Ceph image grows immediately — but the claim does not:

```console
$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd info replicapool/csi-vol-f32c0811-...
rbd image 'csi-vol-f32c0811-373f-414a-9ff1-a96e11e52299':
	size 4 GiB in 1024 objects          <- was 2 GiB in 512 objects

$ kubectl -n ceph-demo get pvc rbd-pvc -o jsonpath='{.spec.resources.requests.storage} / {.status.capacity.storage}'
4Gi / 2Gi
$ kubectl -n ceph-demo get pvc rbd-pvc -o jsonpath='{.status.conditions[0].type}: {.status.conditions[0].message}'
FileSystemResizePending: Waiting for user to (re-)start a pod to finish file system resize of volume on node.
```

Two different components own two different halves of a volume, and only one of
them is in the control plane's hands:

| Step | Who does it | When |
|------|-------------|------|
| grow the block device | the CSI **controller** plugin (`ControllerExpandVolume`) | immediately on the PVC edit |
| grow the filesystem | the CSI **node** plugin (`NodeExpandVolume`), on the node that has the volume | the next time a pod mounts it |

So the fix is a pod — any pod:

```bash
kubectl apply -f pod-rbd-verify.yaml
kubectl -n ceph-demo logs rbd-verify
```

```console
$ kubectl -n ceph-demo logs rbd-verify
--- inside the pod ---
/dev/rbd0                 3.9G     28.0K      3.9G   0% /data
--- the file Lesson 02 wrote ---
written 2026-09-13T05:04:28Z on rbd-writer
expanded and still readable 2026-09-13T05:48:38Z

$ kubectl -n ceph-demo get pvc rbd-pvc
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
rbd-pvc   Bound    pvc-d273d48a-ff10-46d7-8121-64113eb17302   4Gi        RWO            rook-ceph-block
```

The data written in Lesson 02 is still there, `df` shows the new size, and the
claim now agrees with the device.

> ⚠️ **Warning:** if you monitor "PVC capacity < requested capacity" you will page
> someone about a resize that is working exactly as designed. Watch
> `FileSystemResizePending` instead, and remember that a *detached* volume stays
> in that state indefinitely — nothing is wrong until a pod needs it.

## Step 2 — Snapshot it, and restore into a new volume

The API is the one from Lesson 01, unchanged; only the driver name and the Ceph
credentials differ:

```bash
kubectl apply -f snapshotclass-rbd.yaml -f volumesnapshot-rbd.yaml
kubectl -n ceph-demo get volumesnapshot
```

```console
$ kubectl -n ceph-demo get volumesnapshot
NAME           READYTOUSE   SOURCEPVC   RESTORESIZE   SNAPSHOTCLASS             SNAPSHOTCONTENT
rbd-snapshot   true         rbd-pvc     4Gi           rook-ceph-rbd-snapclass   snapcontent-fddc7b7d-35fa-422e-97bb-68c950ea8b6b

$ kubectl -n ceph-demo get volumesnapshotcontent -o custom-columns=DRIVER:.spec.driver,READY:.status.readyToUse,SIZE:.status.restoreSize
DRIVER                       READY   SIZE
hostpath.csi.k8s.io          true    1073741824
rook-ceph.rbd.csi.ceph.com   true    4294967296
```

That second listing is the whole argument for CSI in one screen: a **demo driver
from Lesson 01 and a production Ceph cluster are producing the same
`VolumeSnapshotContent` objects** through the same API. Nothing in your
manifests, your RBAC or your backup tooling has to know which one it is talking
to.

Restoring is a `dataSource`, nothing more:

```bash
kubectl apply -f pvc-rbd-restored.yaml -f pod-rbd-restored.yaml
kubectl -n ceph-demo logs rbd-restored-reader
```

```console
$ kubectl -n ceph-demo logs rbd-restored-reader
--- contents of the volume restored FROM A SNAPSHOT ---
written 2026-09-13T05:04:28Z on rbd-writer
expanded and still readable 2026-09-13T05:48:38Z
/dev/rbd0                 3.9G     28.0K      3.9G   0% /data

$ kubectl -n ceph-demo get pvc
NAME           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
rbd-pvc        Bound    pvc-d273d48a-ff10-46d7-8121-64113eb17302   4Gi        RWO            rook-ceph-block
rbd-restored   Bound    pvc-de1d57fa-539c-45ed-af38-ad0d1a148784   4Gi        RWO            rook-ceph-block
```

> 🏭 **Production:** a snapshot lives *inside* the storage system, so it dies with
> it. Rook/Ceph backups go to an S3 or NFS target through the Ceph CSI
> snapshotter, and Longhorn needs a `backupTarget` configured before `Backup`
> does anything. Snapshot locally for speed; back up off-cluster for survival.

## Step 3 — Kill a storage node

`csilab-worker` holds Ceph's `osd.1` and one replica of every Longhorn volume.
Stopping it is the closest this lab gets to a real failure:

```bash
docker stop csilab-worker
```

Kubernetes notices after about a minute, and both storage systems tell the truth:

```console
$ kubectl get nodes
NAME                   STATUS     ROLES           AGE   VERSION
csilab-control-plane   Ready      control-plane   70m   v1.35.0
csilab-worker          NotReady   <none>          70m   v1.35.0
csilab-worker2         Ready      <none>          70m   v1.35.0

$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
  cluster:
    health: HEALTH_WARN
            1 osds down
            1 host (1 osds) down
            Degraded data redundancy: 55/110 objects degraded (50.000%), 37 pgs degraded, 81 pgs undersized
            (muted: AUTH_INSECURE_KEYS_ALLOWED AUTH_INSECURE_KEYS_CREATABLE)
  services:
    mon: 1 daemons, quorum a (age 56m) [leader: a]
    osd: 2 osds: 1 up (since 3m), 2 in (since 55m)
  data:
    volumes: 1/1 healthy
    pgs:     55/110 objects degraded (50.000%)
             44 active+undersized
             37 active+undersized+degraded

$ kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState
pvc-5ad854d5-...-r-2cd5bde8   csilab-worker2         running
pvc-5ad854d5-...-r-4d90ebaf   csilab-control-plane   running
pvc-5ad854d5-...-r-a5484131   csilab-worker          stopped

$ kubectl -n longhorn-system get nodes.longhorn.io
NAME                   READY   ALLOWSCHEDULING   SCHEDULABLE
csilab-control-plane   True    true              True
csilab-worker          False   true              True
csilab-worker2         True    true              True
```

Read the four things this tells you:

| Observation | Meaning |
|-------------|---------|
| `mon: 1 daemons, quorum a` | the monitor was **not** on the dead node — with `mon: 1` that was luck, not design |
| `1 osds down`, `50.000% degraded` | half the copies are gone, and Ceph says so with numbers rather than adjectives |
| `volumes: 1/1 healthy` | the pool is still serving — `min_size: 1` means one surviving copy is enough for I/O |
| Longhorn `stopped` / `READY False` | Longhorn tracks per-replica and per-node state, and does not pretend a lost replica is fine |

> 🎓 **Insight:** `size: 2` with `min_size: 2` would have blocked writes the moment
> one OSD died — a *configuration* decision that turns a degradation into an
> outage. `ceph osd pool get replicapool min_size` is worth knowing before an
> incident, not during one. (Ceph honours `min_size` even when the cluster is
> otherwise healthy, so this is a knob with a blast radius.)

## Step 4 — Is the volume still usable while degraded?

This is the question that decides whether replication was worth the cost:

```bash
kubectl apply -f pod-rbd-restored.yaml
kubectl -n ceph-demo logs rbd-restored-reader
```

```console
$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd stat
2 osds: 1 up (since 14m), 1 in (since 4m); epoch: e68

$ kubectl -n ceph-demo logs rbd-restored-reader
--- contents of the volume restored FROM A SNAPSHOT ---
written 2026-09-13T05:04:28Z on rbd-writer
expanded and still readable 2026-09-13T05:48:38Z
/dev/rbd0                 3.9G     28.0K      3.9G   0% /data
```

Half the replicas are gone, the cluster is degraded, and a brand-new pod on a
surviving node mounted the volume and read every byte. That is what the extra
copy bought.

## Step 5 — Bring the node back, and watch the simulation end

```bash
docker start csilab-worker
kubectl wait --for=condition=Ready node/csilab-worker --timeout=300s
../00-cluster-setup/prepare-disks.sh csilab-worker
```

Restarting a node container throws away everything that lived in its namespaces:
the Longhorn data-path mount, the `iscsid` socket, the `/dev/rbd*` nodes, and a
writable `/sys`. `prepare-disks.sh` is idempotent precisely so this works, and it
does — the node returns, the fake disks come back, and Longhorn's node goes
`READY True` again.

The OSD does **not** come back:

```console
$ kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide
NAME                               READY   STATUS                  RESTARTS      NODE
rook-ceph-osd-0-6464559b58-g8xtx   1/1     Running                 0             csilab-worker2
rook-ceph-osd-1-675d76dd79-d8gwz   0/1     Init:CrashLoopBackOff   5 (2m32s)     csilab-worker

$ kubectl -n rook-ceph logs rook-ceph-osd-1-... -c expand-bluefs | tail -4
5: (ceph::__ceph_assert_fail(char const*, char const*, int, char const*)+0x18e)
6: ceph-bluestore-tool(+0x191cd7)
reraise_fatal: default handler for signal 6 didn't terminate the process?
```

`activate` succeeds — the log even shows it finding `/dev/loop100` and symlinking
it — and then Rook's `expand-bluefs` init container dies on an assertion inside
`ceph-bluestore-tool`.

> 🧪 **Lab Hack, and its limit:** this is where the fake disk stops behaving like a
> disk. A BlueStore OSD on a real device restarts and rejoins the cluster; on a
> loop device whose backing file lived inside the container that was just stopped,
> the bluestore metadata does not survive the round trip cleanly. The recovery in
> this lab is to treat the OSD as a failed disk: remove it from the CRUSH map,
> wipe the device and let Rook re-provision it, after which Ceph **backfills** the
> missing copies from `osd.0` — which is a real and useful drill, and also a good
> illustration of what `size: 2` costs and buys.
>
> What you should take from the failure is not "Ceph is fragile" but "a container
> is not a node": this whole step exists because kind's nodes are processes on one
> machine with one disk, and Lesson 00 said so out loud before you got here.

## Step 6 — Ceph or Longhorn?

| | Rook Ceph (v1.20.7 / Tentacle v20.2.4) | Longhorn (v1.12.1) |
|---|---|---|
| Install | operator + CRDs + CSI operator + cluster CR; several GB of images | **one Helm chart** |
| What it gives you | block (RBD), shared filesystem (CephFS), object (RGW) | block, plus NFS re-export for RWX |
| Data path | kernel RBD client (`/dev/rbd0`), kernel CephFS | iSCSI login to an engine process, then `/dev/longhorn/<pvc>` |
| Replication unit | objects in placement groups (4MiB), spread by CRUSH | whole-volume replicas, one per node |
| Rebuild cost | only the missing objects move | a full replica is rebuilt |
| Failure domains | host, zone, rack — configurable per pool | nodes only |
| RWX | yes, CephFS, no extra component | yes, through a per-volume NFS `share-manager` pod |
| Snapshots | CSI `VolumeSnapshot` (verified here) | native `Snapshot` CRs; CSI snapshots need explicit enablement |
| Backups | S3/NFS via the CSI snapshotter | S3/NFS via `Backup` + a configured backupstore |
| Minimum useful cluster | 3 nodes for `size: 3`; runs on 1 with `size: 1` | 3 nodes for 3 replicas; works on 1 |
| Operational weight | hours to learn, days to run well | minutes to learn, less to run |
| **This lab** | **block + RWX + expansion + snapshot/restore all verified** | **control plane verified; the V1 data plane cannot attach on kind** |

**Choose Longhorn** when the storage should behave like the rest of your cluster:
a Helm chart, a DaemonSet, CRs you can read, replicas you can count per node, and
no career in Ceph. It is the right default for a platform team that wants
replicated storage without a storage team.

**Choose Ceph** when you need shared filesystems and object storage from the same
system, placement rules finer than "one copy per node", a data path with no
userspace daemon in it, or an ecosystem (RBD mirroring, CephFS, RGW, erasure
coding) that Longhorn simply does not have. You are buying capability with
operational complexity.

**Do not choose either** because "storage is hard" — a single-node `local-path`
claim fails loudly and early; silent replication you do not understand fails
during an incident. Pick the one whose failure modes you have seen.

## Production note

- **What this course verified, and what it did not.** Verified on this cluster:
  Ceph provisioning of RBD, RWX from CephFS, online expansion, CSI snapshots and
  restore, degradation and continued availability with one OSD down. Verified for
  Longhorn: install, disks, node CRs, replica placement on three nodes, and
  replica/node state when a node dies. **Not** verified anywhere: throughput,
  latency, IOPS, real disk failure, multi-zone placement, and Longhorn's data
  plane (see Lesson 03).
- **`mon: 1` is a lab setting.** Here it survived a node loss because the monitor
  happened to live elsewhere. In production run 3 or 5 monitors on separate hosts;
  losing quorum takes the whole cluster down, not just one pool.
- **Replace `Unknown` pods deliberately.** After a node loss, pods on it sit in
  `Unknown` until the node controller gives up on them; both Ceph and Longhorn
  have settings for this (`node-down-pod-deletion-policy`,
  `osdMaintenanceTimeout`, Rook's PDB-managed drains). Knowing which one is
  configured is part of being on call for a storage system.
- **Test the restore, not the backup.** A `VolumeSnapshot` that has never been
  restored into a running pod is a hypothesis.
- **Resize is a two-phase operation** in every CSI driver worth using. Page on
  `FileSystemResizePending` being long-lived, not on capacity lagging the request.

## Next

That is the course. If you want to keep going, the natural next steps are the
questions this lab deliberately left alone: what stops a pod from mounting a
volume it should not (RBAC, admission, `fsGroup`), and how a storage system
behaves under a *real* workload — a database with fsyncs, or a training job
checkpointing every few minutes. `../cleanup.sh` tears this lab down.

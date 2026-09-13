# Lesson 02 — Day-2 operations on Ceph

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
grow a volume, snapshot it, restore it, and kill a node underneath it. It also
shows the one mistake this course made with its own scripts, because a storage lab
that only ever demonstrates clean recovery teaches you to trust your recovery
scripts more than you should.
(The Ceph-vs-Longhorn comparison lives in the [course index](../../README.md), and
the Longhorn lab is a separate cluster.)

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
> snapshotter. Snapshot locally for speed; back up off-cluster for survival.

## Step 3 — Kill a storage node

`csilab-worker` holds Ceph's `osd.1`. Stopping it is the closest this lab gets to a
real failure:

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

```

Read the four things this tells you:

| Observation | Meaning |
|-------------|---------|
| `mon: 1 daemons, quorum a` | the monitor was **not** on the dead node — with `mon: 1` that was luck, not design |
| `1 osds down`, `50.000% degraded` | half the copies are gone, and Ceph says so with numbers rather than adjectives |
| `volumes: 1/1 healthy` | the pool is still serving — `min_size: 1` means one surviving copy is enough for I/O |

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

## Step 5 — Bring the node back, and destroy an OSD by accident

```bash
docker start csilab-worker
kubectl wait --for=condition=Ready node/csilab-worker --timeout=300s
../00-cluster-setup/prepare-disks.sh csilab-worker
```

Restarting a node container throws away everything that lived in its namespaces:
the `/dev/rbd*` nodes and a writable `/sys`. `prepare-disks.sh` is idempotent precisely so this works, and it
does — the node returns and the fake disks come back.

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
`ceph-bluestore-tool`. The first two explanations that came to mind were both
wrong, and the real one is worth the next three paragraphs.

> ⚠️ **The actual cause: this lesson's own recovery command wiped the OSD.**
> `prepare-disks.sh` used to finish its Ceph section with
> `wipefs -a /dev/loopN`, on the reasoning that a lab device sometimes needs its
> old signatures cleared. Run against a cluster that already had an OSD on that
> device, it erased the OSD's **BlueStore metadata** — and `ceph-bluestore-tool`
> then refused to touch a device that no longer identified itself as an OSD.
>
> ```console
> $ wipefs /dev/loop100          # after the wipe
> (no output: no signatures at all)
> $ wipefs /dev/loop101          # the device osd.0 still lives on, for comparison
> DEVICE   OFFSET TYPE           UUID LABEL
> loop101  0x0    ceph_bluestore
> ```
>
> Nothing here is a kind problem, and nothing here is a loop-device problem: a
> setup script that wipes a block device on every run destroys storage, and
> "prepare" is exactly the kind of script people run twice. The fix is in the
> script (`wipefs` is now opt-in via `WIPE_OSD_DEVICE=1`, and off by default), and
> it is verified the same way the bug was found — by re-running the script against
> the *healthy* OSD's device and checking that its signature survives:
>
> ```console
> $ ../00-cluster-setup/prepare-disks.sh
> ...
> left /dev/loop100 signatures alone (WIPE_OSD_DEVICE=1 blanks it on purpose)
> left /dev/loop101 signatures alone (WIPE_OSD_DEVICE=1 blanks it on purpose)
> $ wipefs /dev/loop101
> DEVICE   OFFSET TYPE           UUID LABEL
> loop101  0x0    ceph_bluestore      <- still an OSD
> ```
>
> What this step actually teaches, then, is the thing every storage course should
> teach before it teaches replication: **an OSD is a device plus metadata, and the
> metadata is the part a careless script destroys.** The data on the surviving
> replica is untouched, which is why the drill below still ends well.

### Recovering from it

The device is now blank, so treat it exactly as a failed disk — which is the same
procedure as replacing hardware:

```bash
# 1. take the dead OSD out of the cluster (it is already down)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out osd.1
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd crush remove osd.1
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph auth del osd.1
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd rm osd.1

# 2. remove Rook's record of it, then let the operator prepare the blank device
kubectl -n rook-ceph scale deploy/rook-ceph-osd-1 --replicas=0
kubectl -n rook-ceph delete deploy rook-ceph-osd-1
kubectl -n rook-ceph delete job -l app=rook-ceph-osd-prepare
```

Rook re-runs the OSD prepare for any device in the cluster CR that has no OSD, so
`loop100` is re-provisioned as a fresh OSD and Ceph **backfills** the missing
copies from `osd.0` — no data was lost, because `size: 2` meant a second complete
copy existed the whole time. That backfill is the payoff for the extra copy, and
it is the same process production runs when a disk is replaced.

> 🎓 **Insight:** the honest version of this step is more useful than the tidy one.
> A storage lab that only ever shows clean failure and clean recovery teaches you
> to trust your recovery scripts. This one shows a script destroying an OSD, how it
> was diagnosed (compare the device's signatures against a healthy peer's), how it
> was fixed, and why the cluster survived it anyway.

## Step 6 — Where this leaves you

The lab-verified summary is short: **`rook-ceph-block` gave a block device that a
pod formatted as ext4, it grew online, it snapshotted and restored through the
standard CSI API, and it kept serving reads while half its replicas were gone.**
Those are the four things you will actually ask a storage system to do on a Tuesday.

The head-to-head with Longhorn — including why Longhorn's V1 data engine cannot
attach a volume on kind, and what that says about daemons in a data path — is in
the [course index](../../README.md), next to the Longhorn lab that demonstrates it
on its own cluster.

## Production note

- **What this lab verified, and what it did not.** Verified here: provisioning of
  RBD volumes, RWX from CephFS, online expansion, CSI snapshot and restore,
  degradation, and continued availability with one OSD down. **Not** verified here:
  throughput, latency, IOPS, real disk failure, multi-zone placement, and anything
  about Longhorn — that is a different cluster and a different lab.
- **`mon: 1` is a lab setting.** Here it survived a node loss because the monitor
  happened to live elsewhere. In production run 3 or 5 monitors on separate hosts;
  losing quorum takes the whole cluster down, not just one pool.
- **Replace `Unknown` pods deliberately.** After a node loss, pods on it sit in
  `Unknown` until the node controller gives up on them. Ceph has settings for this
  (`osdMaintenanceTimeout`, Rook's PDB-managed drains); knowing which one is
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
checkpointing every few minutes. `../../cleanup.sh` tears this lab down.

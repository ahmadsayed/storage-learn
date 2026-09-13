# Lesson 02 — Rook Ceph: block storage and a shared filesystem

## Glossary

| Term | What it means |
|------|---------------|
| **Rook** | the operator that deploys and manages Ceph on Kubernetes |
| **Ceph** | the storage system itself: a distributed object store that presents block (RBD), file (CephFS) and object (RGW) interfaces |
| **MON** | monitor — holds the cluster map and the quorum; the source of truth about the cluster |
| **MGR** | manager — runs the modules that report health, metrics and orchestration |
| **OSD** | object storage daemon — one per disk; stores data, serves clients, and replicates to peers |
| **MDS** | metadata server — only needed for CephFS; holds the filesystem namespace |
| **BlueStore** | Ceph's default backend: an OSD writes objects directly to a raw block device |
| **pool** | a logical partition of the cluster with its own replication policy |
| **PG** | placement group — the sharding unit between objects and OSDs |
| **CRUSH** | the algorithm that maps objects to OSDs; `failureDomain: host` makes it spread copies across *nodes*, not disks |
| **RBD** | RADOS Block Device — a virtual block device backed by objects |
| **krbd** | the kernel RBD client, which maps an image to `/dev/rbdN` |
| **CephFS** | a POSIX shared filesystem on top of the same cluster, with an MDS |
| **ceph-csi** | the CSI driver that exposes RBD and CephFS to Kubernetes |
| **toolbox** | a pod with the `ceph`/`rbd` CLIs, wired to the cluster's config and keyring |

Ceph is the heavyweight option: a real distributed storage system with a
replication policy you can reason about, at the cost of an operator, several
daemons and a licence to think about placement groups. This lesson installs a
2-OSD cluster on the two worker "disks" from Lesson 00, then proves it twice —
once with a block volume that a pod formats with ext4, once with a filesystem two
pods on two nodes share at the same time.

## Files

- `cluster.yaml` — the `CephCluster`: the mon/mgr/OSD layout and **which device belongs to which node**.
- `pool-rbd.yaml` — the `CephBlockPool` (`size: 2`, `failureDomain: host`).
- `storageclass-rbd.yaml` — `rook-ceph-block`: RWO block volumes from RBD.
- `filesystem.yaml` — the `CephFilesystem` (`myfs`) plus its metadata and data pools.
- `storageclass-cephfs.yaml` — `rook-cephfs`: RWX volumes from CephFS.
- `namespace.yaml`, `pvc-rbd.yaml`, `pod-rbd.yaml` — a pod that formats and writes to an RBD volume.
- `pvc-cephfs-rwx.yaml`, `pod-rwx-a.yaml`, `pod-rwx-b.yaml` — two pods on two nodes sharing one CephFS volume.

## Step 1 — Install the operator

Everything here is pinned to **Rook v1.20.7** (the Ceph it ships is **Tentacle
v20.2.4**), and the four files must be applied in this order:

```bash
B=https://raw.githubusercontent.com/rook/rook/v1.20.7/deploy/examples
kubectl create -f $B/crds.yaml -f $B/common.yaml -f $B/csi-operator.yaml
kubectl create -f $B/operator.yaml
```

```console
$ kubectl create -f .../csi-operator.yaml ...      # trimmed
driver.csi.ceph.io/rook-ceph.cephfs.csi.ceph.com created
deployment.apps/rook-ceph-operator created
```

> ⚠️ **Warning:** `csi-operator.yaml` is new in Rook 1.20 and is not optional. In
> 1.20 the CSI settings **moved out of the `rook-ceph-operator-config`
> ConfigMap** into `OperatorConfig` and `Driver` custom resources, so the older
> `crds + common + operator` sequence produces a cluster with no CSI drivers at
> all — and no error explaining why.

One of those settings we *do* need here, because our OSD devices are loop devices:

```bash
kubectl -n rook-ceph patch configmap rook-ceph-operator-config \
  --type merge -p '{"data":{"ROOK_CEPH_ALLOW_LOOP_DEVICES":"true"}}'
kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=300s
```

```console
$ kubectl -n rook-ceph get configmap rook-ceph-operator-config -o jsonpath='{.data.ROOK_CEPH_ALLOW_LOOP_DEVICES}'
true
```

> 🧪 **Lab Hack:** `allowLoopDevices` exists precisely for test clusters like
> this one — Rook filters loop devices out of discovery unless it is enabled, and
> without it the OSD prepare job finds "no devices". Rook's own CI avoids loop
> devices entirely and carves real `/dev/sd*` disks out of an iSCSI target
> instead. On hardware you never touch this setting.

> 💡 **Tip:** the operator also created a `Driver` CR per CSI driver. This lab
> shrinks each controller to one replica
> (`kubectl -n rook-ceph patch driver rook-ceph.rbd.csi.ceph.com --type merge -p '{"spec":{"controllerPlugin":{"replicas":1}}}'`)
> to keep the footprint inside a laptop's RAM. Leave the default on a real cluster.

## Step 2 — Tell Ceph which disk belongs to which node

This is the part of the lesson that matters most:

```yaml
storage:
  useAllNodes: false
  useAllDevices: false
  nodes:
    - name: "csilab-worker"
      devices:
        - name: "loop100"
    - name: "csilab-worker2"
      devices:
        - name: "loop101"
```

```bash
kubectl apply -f cluster.yaml
```

Why not `useAllNodes: true, useAllDevices: true`, which is what Rook's example
cluster ships? Because of what the OSD prepare job actually sees. On this
workstation:

```console
$ docker exec csilab-worker sh -c 'lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT /dev/nvme0n1'
NAME          SIZE FSTYPE MOUNTPOINT
nvme0n1     476.9G
|-nvme0n1p1   260M vfat
|-nvme0n1p3  93.1G ntfs
...
`-nvme0n1p9 350.2G btrfs  /etc/hosts
```

A `--privileged` kind node gets the host's device nodes, so the OSD prepare pod
inventories **the laptop's real NVMe** — visible in Rook's own log below. On a
disk that looked empty, "use everything" would have meant "wipe my hard drive".
Naming one device per node is not pedantry; it is the safety rail.

> 🎓 **Insight:** this is the same trap as `lsblk` in Lesson 00, seen from the
> other side. Every node can *see* every loop device in the kernel, so a filter
> like `^loop` would let both workers claim both devices — two OSDs, one backing
> file, two nodes, silent corruption. Per-node device names make that impossible.

## Step 3 — Watch the OSD prepare find exactly that device

```bash
kubectl -n rook-ceph get pods -l app=rook-ceph-osd-prepare
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=-1 | grep -E 'desired devices|skipping device|udevadm'
```

```console
$ kubectl -n rook-ceph logs pod/rook-ceph-osd-prepare-csilab-worker-... | grep ...
I | cephcmd: desired devices to configure osds: [{Name:loop100 OSDsPerDevice:1 ...}]
I | rookcmd: --data-devices=[{"id":"loop100","storeConfig":{"osdsPerDevice":1}}], --node-name=csilab-worker ...
W | inventory: skipping device "loop0". exit status 32
D | sys: lsblk output: "SIZE=\"8589934592\" ROTA=\"0\" ... NAME=\"/dev/loop100\" ... FSTYPE=\"\""
D | exec: Running command: udevadm info --query=property /dev/loop100
W | inventory: skipping device "loop101". exit status 32
D | sys: lsblk output: "... NAME=\"/dev/loop110\" MOUNTPOINT=\"/rootfs/var/lib/longhorn\" ..."
W | inventory: skipping device "nvme0n1" because it has child, considering the child instead.
```

Four things are happening in those few lines, and each one is a lesson:

| Log line | What it tells you |
|----------|-------------------|
| `desired devices ... [{Name:loop100}]` | the per-node device list arrived intact — the operator will only touch this device on this node |
| `udevadm info --query=property /dev/loop100` | ceph-volume asked udev about the device and **got an answer**, because `kind-config.yaml` mounts the host's `/run/udev` into the node |
| `skipping device "loop101"` | the other worker's device is not even a device node inside this node — the private `/dev` from Lesson 00 doing its job |
| `skipping device "nvme0n1"` | your real disk, considered and rejected only because it already has partitions |

Two OSDs came up, one per host:

```console
$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
ID  CLASS  WEIGHT   TYPE NAME                STATUS  REWEIGHT  PRI-AFF
-1         0.01559  root default
-5         0.00780      host csilab-worker
 1    ssd  0.00780          osd.1                up   1.00000  1.00000
-3         0.00780      host csilab-worker2
 0    ssd  0.00780          osd.0                up   1.00000  1.00000
```

> 🧪 **Lab Hack:** the device class is `ssd`. That is Ceph reading `ROTA=0` from a
> loop device, not detecting an SSD. On hardware, `crushDeviceClass` is how you
> decide whether an OSD counts as `hdd`, `ssd` or `nvme`, and getting it wrong
> changes which pools land where.

## Step 4 — Read Ceph's own health, and fix what it complains about

Install the toolbox (it is just a pod with the Ceph CLIs and the cluster's keys):

```bash
B=https://raw.githubusercontent.com/rook/rook/v1.20.7/deploy/examples
kubectl create -f $B/toolbox.yaml
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=240s
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

```console
$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
  cluster:
    id:     5b8c222f-20fc-4799-a8b9-c9b9428d000a
    health: HEALTH_WARN
            Monitors are configured to allow auth using insecure key types
            Monitors are configured to allow creation of insecure key types
            OSD count 2 < osd_pool_default_size 3

  services:
    mon: 1 daemons, quorum a (age 48s) [leader: a]
    mgr: a(active, since 29s)
    osd: 2 osds: 2 up (since 5s), 2 in (since 18s)

  data:
    pools:   0 pools, 0 pgs
    usage:   53 MiB used, 16 GiB / 16 GiB avail
```

Three warnings, two different kinds of problem:

- **`OSD count 2 < osd_pool_default_size 3`** is real and ours. Ceph's default for
  a new pool is 3 replicas; we have 2 OSDs on 2 hosts. Every pool we create would
  be permanently under-replicated. The fix is not to add a third fake disk but to
  set the default to what the cluster can honour: `cephConfig.global.osd_pool_default_size: "2"`.
- **`AUTH_INSECURE_KEYS_*`** is a Tentacle-era compatibility warning about the
  older AES-based cephx key type. Rook's own test cluster sets
  `security.cephx.csi.keyType: aes` for kernels older than 7.0 and then mutes
  exactly these warnings
  ([`cluster-test.yaml`](https://github.com/rook/rook/blob/v1.20.7/deploy/examples/cluster-test.yaml)),
  because they say nothing about whether data is safe. This lab runs on a 7.2.3
  kernel, so it needs no aes setting — and it mutes, rather than fixes, them.

Both are handled in `cluster.yaml`; `ceph status` then reads:

```console
$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
  cluster:
    id:     5b8c222f-20fc-4799-a8b9-c9b9428d000a
    health: HEALTH_OK
            (muted: AUTH_INSECURE_KEYS_ALLOWED AUTH_INSECURE_KEYS_CREATABLE)

  services:
    mon: 1 daemons, quorum a (age 2m) [leader: a]
    mgr: a(active, since 2m)
    osd: 2 osds: 2 up (since 111s), 2 in (since 2m)

  data:
    pools:   1 pools, 1 pgs
    objects: 2 objects, 449 KiB
    usage:   54 MiB used, 16 GiB / 16 GiB avail
    pgs:     1 active+clean
```

> 🎓 **Insight:** Ceph prints `(muted: ...)` in the status line, so a muted
> warning never becomes invisible. That is the honest way to silence a warning you
> have understood: mute it explicitly, and leave the trace where the next person
> will see it.

## Step 5 — RBD: a block volume a pod formats as ext4

```bash
kubectl apply -f pool-rbd.yaml -f storageclass-rbd.yaml
kubectl apply -f namespace.yaml -f pvc-rbd.yaml -f pod-rbd.yaml
kubectl -n ceph-demo logs rbd-writer
```

```console
$ kubectl -n ceph-demo logs rbd-writer
written 2026-09-13T05:04:28Z on rbd-writer
Filesystem                Size      Used Available Use% Mounted on
/dev/rbd0                 1.9G     28.0K      1.9G   0% /data
```

`/dev/rbd0`. Not a `hostPath`, not a directory — a **block device mapped by the
kernel over the network**, formatted with ext4 by the CSI node plugin and handed
to the pod. The Kubernetes-side objects agree:

```console
$ kubectl get pv pvc-d273d48a-... -o custom-columns=DRIVER:.spec.csi.driver,HANDLE:.spec.csi.volumeHandle
DRIVER                       HANDLE
rook-ceph.rbd.csi.ceph.com   0001-0009-rook-ceph-0000000000000002-f32c0811-373f-414a-9ff1-a96e11e52299

$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls -p replicapool
csi-vol-f32c0811-373f-414a-9ff1-a96e11e52299

$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd info replicapool/csi-vol-f32c0811-...
rbd image 'csi-vol-f32c0811-373f-414a-9ff1-a96e11e52299':
	size 2 GiB in 512 objects
	order 22 (4 MiB objects)
	features: layering
```

That `volumeHandle` is the decoder ring: `0001-0009-rook-ceph-<pool-id>-<uuid>`
tells you the cluster's fsid prefix, the pool, and the RBD image — which is why
`rbd ls` and `kubectl get pv` can be matched up by hand when something is wrong.

> ⚠️ **Warning — the failure you will actually hit on kind.** The first attempt
> never mounted:
>
> ```console
> $ kubectl -n ceph-demo describe pod rbd-writer | tail -3
>   Warning  FailedMount  MountVolume.MountDevice failed ... rbd: map failed with error
>   ... rbd: mapping succeeded but /dev/rbd0 is not accessible, is host /dev mounted?
> ```
>
> "Mapping succeeded" is the important half: the kernel *did* create `/dev/rbd0`
> — in the **host's** devtmpfs, which a kind node's private `/dev` tmpfs never
> sees. ceph-csi maps with `--options noudev` and then looks for the device node,
> finds nothing, and retries forever. `prepare-disks.sh` fixes it by creating the
> device nodes inside each node (`mknod /dev/rbd0 b 251 0`; 251 is this kernel's
> rbd major, read from `/proc/devices`). On a real node, devtmpfs creates them on
> demand and none of this exists.

## Step 6 — CephFS: one volume, two nodes, at the same time

RBD is a block device: one writer. For RWX you need CephFS, which is a real
filesystem served over the network and mounted by many clients at once.

```bash
kubectl apply -f filesystem.yaml -f storageclass-cephfs.yaml
kubectl -n rook-ceph get cephfilesystem
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph fs ls
```

```console
$ kubectl -n rook-ceph get cephfilesystem
NAME   ACTIVEMDS   AGE   PHASE
myfs   1           21s   Ready

$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph fs ls
name: myfs, metadata pool: myfs-metadata, data pools: [myfs-replicated ]
```

```bash
kubectl apply -f pvc-cephfs-rwx.yaml -f pod-rwx-a.yaml -f pod-rwx-b.yaml
kubectl -n ceph-demo get pods -o wide
kubectl -n ceph-demo logs rwx-writer
kubectl -n ceph-demo logs rwx-reader
```

```console
$ kubectl -n ceph-demo get pods -o wide       # trimmed
NAME         READY   STATUS    IP            NODE
rwx-reader   1/1     Running   10.244.1.21   csilab-worker2
rwx-writer   1/1     Running   10.244.2.17   csilab-worker

$ kubectl -n ceph-demo get pvc cephfs-rwx
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
cephfs-rwx   Bound    pvc-bbb14b9c-cd46-472f-8624-ebe609621414   2Gi        RWX            rook-cephfs

$ kubectl -n ceph-demo logs rwx-writer
writer wrote:
hello from rwx-writer at 2026-09-13T05:05:09Z

$ kubectl -n ceph-demo logs rwx-reader
reader on rwx-reader sees:
hello from rwx-writer at 2026-09-13T05:05:09Z
```

Two pods, two different nodes, one PVC, and the second one reads what the first
wrote. `ACCESS MODES: RWX` is not decoration — with `rook-ceph-block` this pod
pair is impossible, and the API server would have rejected the second pod's mount.

> 💡 **Tip:** CephFS data is written by the pods directly to the OSDs; the MDS
> only serves metadata. That is why one MDS can serve many clients, and why an
> MDS restart does not lose data — only the namespace operations pause.

## Production note

| Lab choice | What production does instead |
|------------|------------------------------|
| 2 OSDs on loop devices, 2 hosts | many OSDs per host, one per real disk, often with dedicated DB/WAL NVMe |
| `mon: 1` | 3 or 5 monitors, on separate hosts, an odd number for quorum |
| `mgr: 1` | 2 managers (active + standby), which Rook handles automatically |
| `replicated size: 2` | `size: 3` with `failureDomain: host` (or `zone`), for a real failure budget |
| `allowLoopDevices: true` | never set; a real device or nothing |
| Devices named per node | `useAllNodes: true` + a `deviceFilter` that matches your disk naming |
| Dashboard and monitoring off | the dashboard for humans, and the Prometheus exporter for the alerts that page someone |
| `mknod /dev/rbdN` in each node | devtmpfs creates the node when the kernel maps the image |

Two things this lab cannot show you, and will not pretend to:

- **Real disk failure.** `ceph osd` degradation can be simulated by deleting an
  OSD pod, but nothing here can fail the way a disk fails, and with `size: 2` a
  single lost host means no redundancy at all.
- **Performance.** Every loop device shares one NVMe and one page cache. Any
  throughput or latency number from this lab is meaningless, so the course
  publishes none.

## Cleanup

```bash
kubectl delete -f namespace.yaml
kubectl delete -f storageclass-rbd.yaml -f storageclass-cephfs.yaml
kubectl delete -f pool-rbd.yaml -f filesystem.yaml
# then follow Rook's teardown order - the cluster CR refuses to destroy data
# until you tell it to:
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge \
  -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}'
kubectl -n rook-ceph delete cephcluster rook-ceph
```

`../cleanup.sh` does the whole sequence, including the CSI `OperatorConfig` and
`Driver` objects that Rook 1.20 adds and the older teardown docs do not mention.

## Next

Continue to [Lesson 03 — Longhorn: replicated volumes the easy way](../03-longhorn/README.md).

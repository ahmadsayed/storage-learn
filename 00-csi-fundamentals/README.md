# Lesson 00 — CSI fundamentals: PV, PVC, StorageClass, and where CSI plugs in

## Glossary

| Term | What it means |
|------|---------------|
| **PV** (PersistentVolume) | the supply side: a piece of storage that exists in the cluster |
| **PVC** (PersistentVolumeClaim) | the demand side: "I want 1Gi, ReadWriteOnce" — a pod only ever names a PVC |
| **StorageClass** | the recipe a PVC asks for; names the provisioner and the binding policy |
| **static provisioning** | a human creates the PV, a PVC binds to it |
| **dynamic provisioning** | a controller creates the PV when a PVC asks for it |
| **CSI** | Container Storage Interface — the gRPC protocol between kubelet and a storage driver |
| **controller plugin** | the part that talks to the storage API (create/delete/attach/snapshot): usually a Deployment |
| **node plugin** | the part that runs on every node and mounts the volume: usually a DaemonSet |
| **sidecar** | upstream helper (`csi-provisioner`, `csi-attacher`, `csi-snapshotter`, …) that translates Kubernetes objects into CSI calls |
| **`WaitForFirstConsumer`** | do not provision until a pod is scheduled — required for node-local storage |
| **`VolumeAttachment`** | the object recording "this volume is attached to this node"; a CSI driver's attach has a paper trail |
| **snapshot API** | `snapshot.storage.k8s.io` — a *separate* API you install, then a driver implements it |

This lesson provisions the same 1Gi volume three ways — a hand-written PV, a
non-CSI provisioner, and a real CSI driver — and the point is the table at the
end: **dynamic and CSI are not the same word**. It finishes by installing the
Kubernetes CSI reference driver, which is the sandbox the rest of the course
compares against.

## Files

- `namespace.yaml` — namespace `csi-basics`, where all demo objects live.
- `pv-manual.yaml`, `pvc-manual.yaml`, `pod-manual.yaml` — static provisioning.
- `pvc-missing-class.yaml` — the failure everyone hits at least once.
- `pvc-localpath.yaml`, `pod-localpath.yaml` — dynamic provisioning without CSI.
- `storageclass-hostpath.yaml`, `pvc-hostpath.yaml`, `pod-hostpath.yaml` — the CSI path.
- `snapshotclass-hostpath.yaml`, `volumesnapshot.yaml`, `pvc-restored.yaml`, `pod-restored.yaml` — snapshot and restore.

## Step 1 — Bind a PVC to a PV you created by hand

A `local` PV means "a path on one specific node", so the PV can only ever be used
by pods on that node. Create that path first, then the objects:

```bash
docker exec csilab-worker mkdir -p /mnt/csi-basics/manual-pv

kubectl apply -f namespace.yaml -f pv-manual.yaml -f pvc-manual.yaml
kubectl -n csi-basics get pv,pvc
```

The claim does not name the volume. The PV controller has to *match* them on
class, access mode and capacity:

```console
$ kubectl -n csi-basics get pv,pvc
NAME                         CAPACITY   ...   STATUS   CLAIM                   STORAGECLASS
persistentvolume/manual-pv   1Gi        ...   Bound    csi-basics/manual-pvc   manual

NAME                               STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/manual-pvc   Bound    manual-pv   1Gi        RWO            manual
```

```bash
kubectl -n csi-basics apply -f pod-manual.yaml
kubectl -n csi-basics logs manual-writer
```

```console
$ kubectl -n csi-basics logs manual-writer
--- /data/proof.txt ---
written 2026-09-13T04:46:57Z by manual-writer
```

Nothing in that path knows what CSI is. That is worth holding on to: the
PV/PVC/StorageClass model predates CSI and is deliberately driver-agnostic.

## Step 2 — Ask for a StorageClass that does not exist

The most common storage bug in the world:

```bash
kubectl -n csi-basics apply -f pvc-missing-class.yaml
kubectl -n csi-basics describe pvc pvc-missing-class | tail -5
```

```console
$ kubectl -n csi-basics get pvc pvc-missing-class
NAME                STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS                AGE
pvc-missing-class   Pending                                      this-class-does-not-exist   5s

$ kubectl -n csi-basics describe pvc pvc-missing-class | tail -5   # trimmed to the load-bearing line
  Warning  ProvisioningFailed  persistentvolume-controller  storageclass.storage.k8s.io "this-class-does-not-exist" not found
```

`Pending` is the only symptom a pod gives you here, and the pod's own message
("PVC is not bound") says nothing about the cause. Get in the habit of reading
the **PVC's** events, not the pod's.

## Step 3 — Dynamic provisioning, with no CSI driver anywhere

kind ships a StorageClass, and it is not CSI:

```console
$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

```bash
kubectl -n csi-basics apply -f pvc-localpath.yaml -f pod-localpath.yaml
kubectl -n csi-basics logs localpath-writer
```

```console
$ kubectl -n csi-basics logs localpath-writer
written by the local-path provisioner

$ kubectl -n csi-basics get pvc localpath-pvc
NAME            STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
localpath-pvc   Bound    pvc-951a6da7-607b-429d-baf1-d7f8199228c3   1Gi        RWO            standard
```

A volume was provisioned dynamically — and there is still no CSI driver in the
cluster. Look at what the "volume" actually is:

```console
$ kubectl get pv pvc-951a6da7-... -o jsonpath='{.spec.csi}'
                                          <- empty: this PV has no CSI section at all

$ kubectl get pv pvc-951a6da7-... -o jsonpath='{.spec.hostPath.path}  {.spec.nodeAffinity...values[0]}'
/var/local-path-provisioner/pvc-951a6da7-..._csi-basics_localpath-pvc  csilab-worker
```

`hostPath` + a node name. The data lives on one node's disk, and if that pod ever
moves, the volume does not follow it. That is exactly the gap a real CSI driver
closes.

> ⚠️ **Warning — a trap you will hit for real.** These pods use
> `nodeSelector: kubernetes.io/hostname`, not `nodeName:`. The first version of
> this lesson used `nodeName` and the volume never provisioned:
>
> ```console
> $ kubectl -n csi-basics describe pod localpath-writer | tail -3
>   Warning  FailedMount  Unable to attach or mount volumes: ... PVC is not bound
> ```
>
> `nodeName` bypasses the scheduler, and with `WaitForFirstConsumer` the
> provisioner waits for the annotation `volume.kubernetes.io/selected-node` —
> which only the scheduler writes. No scheduler, no annotation, no volume,
> forever. Pinning by `nodeSelector` still keeps the lesson deterministic.

## Step 4 — Install the snapshot API

Snapshots are **not** part of the core API. The CRDs and a controller come from
[external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter),
pinned here to `v8.6.0` — the same version the reference driver's snapshotter
sidecar and Rook v1.20 ship, so nothing is talking past anything else:

```bash
SS=https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0
kubectl apply -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
                -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
                -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f $SS/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml \
                -f $SS/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=180s
```

```console
$ kubectl get crd | grep snapshot.storage
volumesnapshotclasses.snapshot.storage.k8s.io     2026-09-13T04:50:45Z
volumesnapshotcontents.snapshot.storage.k8s.io    2026-09-13T04:50:45Z
volumesnapshots.snapshot.storage.k8s.io           2026-09-13T04:50:45Z
```

> 🎓 **Insight:** the split matters. The *controller* is a cluster-wide component
> that watches `VolumeSnapshot` objects; the *sidecar* (`csi-snapshotter`) runs
> beside a driver's controller and turns those objects into CSI calls. Install the
> controller once; every driver then only needs its sidecar.

## Step 5 — Install the Kubernetes CSI reference driver

[`csi-driver-host-path`](https://github.com/kubernetes-csi/csi-driver-host-path)
is the driver Kubernetes' own end-to-end tests and documentation use. It is
deliberately not production software: it stores volumes in directories on one
node, exactly like `local-path` — but it speaks **real CSI**, which is the point.

```bash
git clone --depth 1 --branch v1.18.0 https://github.com/kubernetes-csi/csi-driver-host-path.git
cd csi-driver-host-path/deploy/kubernetes-1.35     # must match your cluster's minor version
./deploy.sh
```

```console
$ ./deploy.sh            # trimmed: the RBAC bindings and the snapshot class land first
serviceaccount/csi-hostpathplugin-sa created
clusterrolebinding.rbac.authorization.k8s.io/csi-hostpathplugin-provisioner-cluster-role created
...
statefulset.apps/csi-hostpathplugin created
volumesnapshotclass.snapshot.storage.k8s.io/csi-hostpath-snapclass created
service/hostpath-service created
statefulset.apps/csi-hostpath-socat created
```

> 💡 **Tip:** the driver installs into the `default` namespace (upstream's choice,
> not this course's). Delete it with `cd deploy/kubernetes-1.35 && ./destroy.sh`.

## Step 6 — A volume that is actually served by CSI

```bash
kubectl apply -f storageclass-hostpath.yaml -f pvc-hostpath.yaml -f pod-hostpath.yaml
kubectl -n csi-basics logs hostpath-writer
```

```console
$ kubectl -n csi-basics logs hostpath-writer
written by the CSI hostpath driver

$ kubectl get pv pvc-054c436f-... -o jsonpath='{.spec.csi}'
{"driver":"hostpath.csi.k8s.io","volumeAttributes":{"storage.kubernetes.io/csiProvisionerIdentity":"1789275122842-7418-hostpath.csi.k8s.io"},"volumeHandle":"ec39a15d-af2e-11f1-966e-26d4c8c07d05"}
```

There it is: `driver`, provider identity, and a `volumeHandle` that is the
driver's own identifier for the volume. This is the difference between Step 3 and
Step 6, and it is the only difference a pod can see.

The rest of the CSI surface, all of it inspectable:

```console
$ kubectl get csidrivers
NAME                  ATTACHREQUIRED   PODINFOONMOUNT   STORAGECAPACITY   MODES
hostpath.csi.k8s.io   true             true             false             Persistent,Ephemeral

$ kubectl get csinodes
NAME                   DRIVERS
csilab-control-plane   0
csilab-worker          1
csilab-worker2         0

$ kubectl get volumeattachments
NAME                        ATTACHER              PV                                         NODE            ATTACHED
csi-1008841326b5bd34...     hostpath.csi.k8s.io   pvc-054c436f-c085-40a7-a520-95725d705b7e   csilab-worker   true

$ docker exec csilab-worker ls /var/lib/kubelet/plugins/ /var/lib/kubelet/plugins_registry/
/var/lib/kubelet/plugins/:
csi-hostpath

/var/lib/kubelet/plugins_registry/:
hostpath.csi.k8s.io-reg.sock
```

Read those four together:

| Object / path | What it proves |
|---------------|----------------|
| `csidrivers/hostpath.csi.k8s.io` | the driver told the API server who it is; `ATTACHREQUIRED: true` means it implements controller publish/unpublish |
| `csinodes` `DRIVERS: 1` on one node only | the *node plugin* registered itself with that node's kubelet over the socket in `plugins_registry/` |
| `VolumeAttachment` | the controller plugin was asked to attach, and has not yet been asked to detach |
| `/var/lib/kubelet/plugins/csi-hostpath` | the unix socket kubelet dials to call `NodeStageVolume`, `NodePublishVolume`, … |

> 🎓 **Insight:** the driver name `hostpath.csi.k8s.io` appears in four places —
> the CSIDriver object, the `csinodes` registration, the StorageClass
> `provisioner` field, and the PV's `spec.csi.driver`. They must agree, and
> "volume won't mount, everything looks fine" is almost always a typo in one of
> them.

## Step 7 — Snapshot it, and restore into a new volume

```bash
kubectl -n csi-basics apply -f snapshotclass-hostpath.yaml -f volumesnapshot.yaml
kubectl -n csi-basics get volumesnapshot
kubectl -n csi-basics get volumesnapshotcontent
```

```console
$ kubectl -n csi-basics get volumesnapshot
NAME                READYTOUSE   SOURCEPVC      RESTORESIZE   SNAPSHOTCLASS            SNAPSHOTCONTENT
hostpath-snapshot   true         hostpath-pvc   1Gi           csi-hostpath-snapclass   snapcontent-14e1599a-ba25-488e-ae61-c73226a20660

$ kubectl -n csi-basics get volumesnapshotcontent -o custom-columns=NAME:.metadata.name,DRIVER:.spec.driver,READY:.status.readyToUse,SIZE:.status.restoreSize
NAME                                               DRIVER                READY   SIZE
snapcontent-14e1599a-ba25-488e-ae61-c73226a20660   hostpath.csi.k8s.io   true    1073741824
```

Two objects, and the split is the same pattern as PV/PVC: `VolumeSnapshot` is the
request in the user's namespace, `VolumeSnapshotContent` is the thing the driver
made, owned by the cluster. Now ask for a PVC whose source is that snapshot:

```bash
kubectl -n csi-basics apply -f pvc-restored.yaml -f pod-restored.yaml
kubectl -n csi-basics logs restored-reader
```

```console
$ kubectl -n csi-basics logs restored-reader
--- /data/proof.txt inside the restored volume ---
written by the CSI hostpath driver
```

The file written in Step 6 is readable from a volume that never existed before
this moment. `dataSource` in the PVC is all it took — no `dd`, no copy job.

## The four volumes, side by side

```console
$ kubectl -n csi-basics get pvc
NAME                STATUS    VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS
hostpath-pvc        Bound     pvc-054c...  1Gi       RWO            csi-hostpath-sc
localpath-pvc       Bound     pvc-951a...  1Gi       RWO            standard
manual-pvc          Bound     manual-pv    1Gi       RWO            manual
pvc-missing-class   Pending                                        this-class-does-not-exist
restored-pvc        Bound     pvc-1e30...  1Gi       RWO            csi-hostpath-sc
```

| | `manual-pv` | `standard` (local-path) | `csi-hostpath-sc` |
|---|---|---|---|
| Who created the PV | you, in YAML | a provisioner | a CSI controller plugin |
| Dynamic | no | **yes** | **yes** |
| CSI | no | **no** | **yes** |
| `pv.spec.csi` | absent | absent | driver + volumeHandle |
| Snapshots | n/a | not supported | works (Step 7) |
| Survives the pod moving nodes | no | no | no — *this* driver is node-local too |

> 🎓 **Insight:** that last row is the one to carry into Lesson 02. Being CSI does
> not make storage replicated or highly available. CSI is a *protocol*: it says
> how kubelet and a driver talk, not what the driver does behind the socket. The
> hostpath driver is CSI and loses your data when a node dies; `local-path` is not
> CSI and behaves identically. Rook Ceph and Longhorn are CSI **and** replicate.

## Production note

- **Never use `csi-driver-host-path` outside a lab.** Upstream says so in the
  repository's first paragraph — it is a test fixture.
- **The snapshot API is a cluster-wide one-time install.** Production clusters
  usually get it from the distribution or a CSI driver's own bundle (Rook ships
  it; Longhorn and others document their own path). Install it *before* the
  drivers, and keep the version at or below the `csi-snapshotter` sidecar's
  version.
- **`reclaimPolicy: Delete` is the default everywhere here.** Deleting a PVC in
  this lesson deletes the volume and the data with it. `Retain` is what you want
  for anything you are unsure about.
- **Access modes are the driver's promise, not a filesystem guarantee.**
  `ReadWriteOnce` here means "one node", not "one pod", and whether
  `ReadWriteMany` is possible at all depends on the driver — Lesson 02 gets RWX
  from CephFS, and Lesson 03 from Longhorn's NFS share-manager.

## Cleanup

```bash
kubectl delete namespace csi-basics
# and, from the driver checkout:
cd csi-driver-host-path/deploy/kubernetes-1.35 && ./destroy.sh
```

The snapshot CRDs, the snapshot controller and the driver's `VolumeSnapshotClass`
are cluster-wide; `../cleanup.sh` removes them along with the cluster.

## Next

Run the [Ceph lab](../ceph-lab/README.md) next: that is where this cluster gets a real CSI
driver, and where `local-path` is replaced by storage that survives a node dying.

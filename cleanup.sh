#!/usr/bin/env bash
# cleanup.sh — tear down everything the CSI storage course created. Safe to re-run.
#
# Order matters more than usual here, and in two places it is the difference
# between a clean re-run and a machine that fights you:
#
#   1. Longhorn refuses to uninstall until you flip deleting-confirmation-flag.
#   2. Rook refuses to delete a CephCluster until you confirm data destruction.
#   3. The loop devices live in the HOST kernel. Deleting a kind node while one is
#      still attached to a file inside that node leaves the kernel holding a
#      device whose backing file no longer exists - which is how you end up with
#      "(lost)" entries in `losetup -a` and a cluster that will not come back
#      cleanly. Detach them BEFORE `kind delete`.
#
#   ./cleanup.sh                 # everything, including the cluster
#   KEEP_CLUSTER=1 ./cleanup.sh  # uninstall the storage systems, keep the nodes
#
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-csilab}"
NODES=(csilab-control-plane csilab-worker csilab-worker2)
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

# Talk to the lab cluster without touching the caller's default kubeconfig.
if [ -z "${KUBECONFIG:-}" ] && [ -f "$(dirname "$0")/.csi-lab.kubeconfig" ]; then
  export KUBECONFIG="$(cd "$(dirname "$0")" && pwd)/.csi-lab.kubeconfig"
fi
K() { kubectl "$@"; }

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
have_cluster() { K get --raw /version >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
step "1/8 Delete the workloads (their PVCs take the volumes with them)"
for ns in ceph-demo csi-basics lh-demo storage-day2; do
  if K get ns "$ns" >/dev/null 2>&1; then
    K delete ns "$ns" --wait=true --timeout=180s >/dev/null 2>&1 \
      && echo "  deleted namespace $ns" || echo "  namespace $ns did not finish deleting"
  else
    echo "  no namespace $ns"
  fi
done

if have_cluster; then
  # StorageClasses are cluster-scoped and outlive their namespaces.
  for sc in rook-ceph-block rook-cephfs csi-hostpath-sc longhorn longhorn-static; do
    K delete storageclass "$sc" --ignore-not-found >/dev/null 2>&1 && echo "  storageclass $sc gone"
  done
  K delete volumesnapshotclass --all >/dev/null 2>&1 && echo "  volume snapshot classes gone"
fi

# ---------------------------------------------------------------------------
step "2/8 Uninstall Longhorn"
if have_cluster && K get ns longhorn-system >/dev/null 2>&1; then
  # Without this flag the uninstall job fails by design.
  K -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
    --type=merge -p '{"value":"true"}' >/dev/null 2>&1 && echo "  deleting-confirmation-flag set"
  if command -v helm >/dev/null 2>&1 && helm -n longhorn-system list -q 2>/dev/null | grep -qx longhorn; then
    helm -n longhorn-system uninstall longhorn >/dev/null 2>&1 && echo "  helm release removed"
  fi
  K create -f https://raw.githubusercontent.com/longhorn/longhorn/v1.12.1/uninstall/uninstall.yaml >/dev/null 2>&1
  K -n longhorn-system wait --for=condition=complete job/longhorn-uninstall --timeout=240s >/dev/null 2>&1 \
    && echo "  uninstall job completed" || echo "  uninstall job did not complete (namespace may need a manual delete)"
  K -n longhorn-system delete pods --all --grace-period=5 >/dev/null 2>&1
  K delete ns longhorn-system --wait=true --timeout=120s >/dev/null 2>&1 \
    && echo "  namespace longhorn-system gone" || echo "  namespace longhorn-system still terminating"
  K delete crd -l app.kubernetes.io/name=longhorn --ignore-not-found >/dev/null 2>&1
  for crd in $(K get crd -o name 2>/dev/null | grep longhorn.io); do
    K delete "$crd" --ignore-not-found >/dev/null 2>&1
  done
  echo "  longhorn CRDs removed"
else
  echo "  longhorn-system not installed"
fi

# ---------------------------------------------------------------------------
step "3/8 Delete the Ceph cluster (Ceph keeps data until you say otherwise)"
if have_cluster && K get ns rook-ceph >/dev/null 2>&1; then
  K -n rook-ceph delete cephfilesystem myfs --ignore-not-found >/dev/null 2>&1 && echo "  cephfilesystem myfs deleted"
  K -n rook-ceph delete cephblockpool replicapool --ignore-not-found >/dev/null 2>&1 && echo "  cephblockpool replicapool deleted"
  K -n rook-ceph patch cephcluster rook-ceph --type merge \
    -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}' >/dev/null 2>&1 \
    && echo "  cleanupPolicy confirmed - Ceph may now destroy its data"
  K -n rook-ceph delete cephcluster rook-ceph --wait=false >/dev/null 2>&1 && echo "  cephcluster deleting"
  echo "  waiting for the cleanup jobs to zap the OSD devices..."
  for _ in $(seq 1 30); do
    K -n rook-ceph get cephcluster rook-ceph >/dev/null 2>&1 || break
    sleep 10
  done
else
  echo "  rook-ceph not installed"
fi

# ---------------------------------------------------------------------------
step "4/8 Remove the Rook operator, CSI operator CRs, RBAC and CRDs"
if have_cluster; then
  for cr in operatorconfigs drivers clientprofiles clientprofilemappings cephconnections; do
    K -n rook-ceph delete "$cr.csi.ceph.io" --all --ignore-not-found >/dev/null 2>&1
  done
  echo "  ceph-csi-operator custom resources removed (new in Rook 1.20 - older teardown docs miss these)"
  B=https://raw.githubusercontent.com/rook/rook/v1.20.7/deploy/examples
  for f in operator.yaml csi-operator.yaml common.yaml crds.yaml; do
    K delete -f "$B/$f" --ignore-not-found >/dev/null 2>&1 && echo "  deleted $f"
  done
  K delete ns rook-ceph --wait=true --timeout=180s >/dev/null 2>&1 \
    && echo "  namespace rook-ceph gone" || echo "  namespace rook-ceph still terminating (check for leftover finalizers)"
fi

# ---------------------------------------------------------------------------
step "5/8 Remove the reference driver and the snapshot API from Lesson 01"
if have_cluster; then
  HOSTPATH_DIR="${HOSTPATH_DIR:-}"
  for d in "$HOSTPATH_DIR" "$HOME/csi-driver-host-path" "$(dirname "$0")/csi-driver-host-path"; do
    if [ -n "$d" ] && [ -f "$d/deploy/kubernetes-latest/destroy.sh" ]; then
      (cd "$(dirname "$d")" && : ) # no-op keeps the path resolution obvious
      (cd "$d" && ./deploy/kubernetes-latest/destroy.sh >/dev/null 2>&1) \
        && echo "  csi-driver-host-path destroyed (from $d)"
      break
    fi
  done
  SS=https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0
  K delete -f $SS/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml --ignore-not-found >/dev/null 2>&1
  K delete -f $SS/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml --ignore-not-found >/dev/null 2>&1
  K delete -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
           -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
           -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml --ignore-not-found >/dev/null 2>&1
  echo "  snapshot CRDs and controller removed"
fi

# ---------------------------------------------------------------------------
step "6/8 Undo the node-side lab hacks (inside the nodes, before they are deleted)"
for NODE in "${NODES[@]}"; do
  if docker inspect "$NODE" >/dev/null 2>&1; then
    docker exec "$NODE" sh -c '
      umount /var/lib/longhorn 2>/dev/null
      for f in /var/lib/rook-osd/osd.img /var/lib/longhorn-disk.img; do
        for d in $(losetup -j "$f" 2>/dev/null | cut -d: -f1); do losetup -d "$d" 2>/dev/null; done
      done
      losetup -D 2>/dev/null
      rm -f /var/lib/rook-osd/osd.img /var/lib/longhorn-disk.img
    ' >/dev/null 2>&1 && echo "  $NODE: mounts unmounted, loop devices detached, backing files removed"
  else
    echo "  $NODE: no such container"
  fi
done
echo "  NOTE: /dev/loop* device node *files* may survive inside the node's /dev;"
echo "        they are meaningless without a backing device and vanish with the node."

# ---------------------------------------------------------------------------
step "7/8 Delete the cluster"
if [ "$KEEP_CLUSTER" = "1" ]; then
  echo "  KEEP_CLUSTER=1, leaving $CLUSTER_NAME running"
elif command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME" && echo "  kind cluster $CLUSTER_NAME deleted"
else
  echo "  no kind cluster named $CLUSTER_NAME"
fi

# ---------------------------------------------------------------------------
step "8/8 Check for leaked host state"
LEFT=$(losetup -a 2>/dev/null | grep -c lost || true)
if [ "${LEFT:-0}" -gt 0 ]; then
  echo "  WARNING: losetup reports $LEFT stale (lost) loop devices, from an earlier unclean teardown:"
  losetup -a 2>/dev/null | grep lost | sed 's/^/    /'
  echo "    They are harmless until the next reboot; detach with: sudo losetup -d <device>"
else
  echo "  no stale loop devices"
fi

cat <<'EOF'

Intentionally left in place
  * kernel modules loaded on the host: rbd, iscsi_tcp (harmless, gone at reboot)
  * docker images: ceph, longhorn, csi sidecars (delete with: docker image prune)
  * the host's /sys mount flags (a kind node remounts only its own namespaces)
EOF

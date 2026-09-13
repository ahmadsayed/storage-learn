#!/usr/bin/env bash
# cleanup.sh — remove both labs. Safe to re-run, and safe to run when only one of
# them exists.
#
# The two labs are independent: the Ceph lab owns the cluster `csilab`, the
# Longhorn lab owns `lhslab`. So this script *checks what is there* at every step
# instead of assuming a state:
#
#   * a cluster that does not exist is skipped, not an error
#   * a storage system that was never installed is skipped
#   * a teardown step that is already done is skipped
#
# Order matters, and in three places it is the difference between a clean re-run
# and a machine that fights you:
#
#   1. Longhorn refuses to uninstall until deleting-confirmation-flag is set.
#   2. Rook refuses to delete a CephCluster until you confirm data destruction.
#   3. The loop devices live in the HOST kernel. Deleting a kind node while one is
#      still attached to a file inside it leaves the kernel holding a device whose
#      backing file no longer exists. Detach them BEFORE `kind delete`.
#
#   ./cleanup.sh                 # both labs
#   ./cleanup.sh ceph            # only the Ceph lab
#   ./cleanup.sh longhorn        # only the Longhorn lab
#   KEEP_CLUSTERS=1 ./cleanup.sh # uninstall the storage systems, keep the nodes
#
set -uo pipefail

WHICH="${1:-both}"
KEEP_CLUSTERS="${KEEP_CLUSTERS:-0}"

CEPH_CLUSTER="${CEPH_CLUSTER:-csilab}"
LH_CLUSTER="${LH_CLUSTER:-lhslab}"
CEPH_NODES=(csilab-control-plane csilab-worker csilab-worker2)
LH_NODES=(lhslab-control-plane lhslab-worker lhslab-worker2)
NS_TO_PURGE=(ceph-demo csi-basics lh-demo storage-day2)

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

kind_has() { command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$1"; }
kubeconfig_for() {
  case "$1" in
    "$CEPH_CLUSTER") [ -f "$(dirname "$0")/.csi-lab.kubeconfig" ] && echo "$(cd "$(dirname "$0")" && pwd)/.csi-lab.kubeconfig" ;;
    "$LH_CLUSTER")   [ -f "$(dirname "$0")/.lhslab.kubeconfig" ] && echo "$(cd "$(dirname "$0")" && pwd)/.lhslab.kubeconfig" ;;
  esac
}
# Run kubectl against one lab's cluster without disturbing the caller's config.
K() { local cfg; cfg="$(kubeconfig_for "$1")"; shift; if [ -n "$cfg" ]; then KUBECONFIG="$cfg" kubectl "$@"; else kubectl "$@"; fi; }
reachable() { K "$1" get --raw /version >/dev/null 2>&1; }

want_ceph=0; want_lh=0
case "$WHICH" in
  both)     want_ceph=1; want_lh=1 ;;
  ceph)     want_ceph=1 ;;
  longhorn) want_lh=1 ;;
  *) echo "usage: $0 [both|ceph|longhorn]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
step "1/6 Delete the workloads in whichever lab clusters exist"
for cluster in $CEPH_CLUSTER $LH_CLUSTER; do
  kind_has "$cluster" || { echo "  $cluster: not running, skipping"; continue; }
  reachable "$cluster" || { echo "  $cluster: not reachable with kubectl, skipping"; continue; }
  for ns in "${NS_TO_PURGE[@]}"; do
    if K "$cluster" get ns "$ns" >/dev/null 2>&1; then
      K "$cluster" delete ns "$ns" --wait=true --timeout=180s >/dev/null 2>&1 \
        && echo "  $cluster: deleted namespace $ns" \
        || echo "  $cluster: namespace $ns did not finish deleting"
    fi
  done
  for sc in rook-ceph-block rook-cephfs csi-hostpath-sc longhorn longhorn-static; do
    if K "$cluster" get storageclass "$sc" >/dev/null 2>&1; then
      K "$cluster" delete storageclass "$sc" >/dev/null 2>&1 && echo "  $cluster: storageclass $sc removed"
    fi
  done
done

# ---------------------------------------------------------------------------
step "2/6 Ceph lab: destroy the Ceph cluster, then the operator"
if [ "$want_ceph" = "1" ] && kind_has "$CEPH_CLUSTER" && reachable "$CEPH_CLUSTER"; then
  if K "$CEPH_CLUSTER" get ns rook-ceph >/dev/null 2>&1; then
    K "$CEPH_CLUSTER" -n rook-ceph delete cephfilesystem myfs --ignore-not-found >/dev/null 2>&1 \
      && echo "  cephfilesystem myfs deleted"
    K "$CEPH_CLUSTER" -n rook-ceph delete cephblockpool replicapool --ignore-not-found >/dev/null 2>&1 \
      && echo "  cephblockpool replicapool deleted"
    if K "$CEPH_CLUSTER" get cephcluster rook-ceph >/dev/null 2>&1; then
      K "$CEPH_CLUSTER" -n rook-ceph patch cephcluster rook-ceph --type merge \
        -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}' >/dev/null 2>&1 \
        && echo "  cleanupPolicy confirmed — Ceph may now destroy its data"
      K "$CEPH_CLUSTER" -n rook-ceph delete cephcluster rook-ceph --wait=false >/dev/null 2>&1
      echo "  waiting for the Ceph cluster to go away..."
      for _ in $(seq 1 30); do
        K "$CEPH_CLUSTER" get cephcluster rook-ceph >/dev/null 2>&1 || break
        sleep 10
      done
      if K "$CEPH_CLUSTER" get cephcluster rook-ceph >/dev/null 2>&1; then
        echo "  cephcluster still present (leftover finalizers?)"
      else
        echo "  cephcluster gone"
      fi
    else
      echo "  no cephcluster to delete"
    fi
    # New in Rook 1.20: the CSI settings live in CRs, and older teardown docs miss them.
    for cr in operatorconfigs drivers clientprofiles clientprofilemappings cephconnections; do
      K "$CEPH_CLUSTER" -n rook-ceph delete "$cr.csi.ceph.io" --all --ignore-not-found >/dev/null 2>&1
    done
    echo "  ceph-csi-operator custom resources removed"
    B=https://raw.githubusercontent.com/rook/rook/v1.20.7/deploy/examples
    for f in operator.yaml csi-operator.yaml common.yaml crds.yaml; do
      K "$CEPH_CLUSTER" delete -f "$B/$f" --ignore-not-found >/dev/null 2>&1 && echo "  deleted $f"
    done
    K "$CEPH_CLUSTER" delete ns rook-ceph --wait=true --timeout=180s >/dev/null 2>&1 \
      && echo "  namespace rook-ceph gone" || echo "  namespace rook-ceph still terminating"
  else
    echo "  rook-ceph not installed"
  fi
else
  echo "  Ceph lab cluster not present, skipping"
fi

# ---------------------------------------------------------------------------
step "3/6 Longhorn lab: uninstall Longhorn"
if [ "$want_lh" = "1" ] && kind_has "$LH_CLUSTER" && reachable "$LH_CLUSTER"; then
  if K "$LH_CLUSTER" get ns longhorn-system >/dev/null 2>&1; then
    # Without this flag the uninstall fails, by design.
    K "$LH_CLUSTER" -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
      --type=merge -p '{"value":"true"}' >/dev/null 2>&1 && echo "  deleting-confirmation-flag set"
    if command -v helm >/dev/null 2>&1; then
      cfg="$(kubeconfig_for "$LH_CLUSTER")"
      if [ -n "$cfg" ]; then
        helm --kubeconfig "$cfg" -n longhorn-system uninstall longhorn >/dev/null 2>&1 \
          && echo "  helm release uninstalled"
      else
        helm -n longhorn-system uninstall longhorn >/dev/null 2>&1 && echo "  helm release uninstalled"
      fi
    fi
    echo "  waiting for longhorn-system to empty..."
    for _ in $(seq 1 24); do
      K "$LH_CLUSTER" get ns longhorn-system >/dev/null 2>&1 || break
      sleep 5
    done
    K "$LH_CLUSTER" delete ns longhorn-system --wait=false >/dev/null 2>&1
    for crd in $(K "$LH_CLUSTER" get crd -o name 2>/dev/null | grep 'longhorn\.io'); do
      K "$LH_CLUSTER" delete "$crd" --ignore-not-found >/dev/null 2>&1
    done
    echo "  longhorn CRDs and namespace removed"
  else
    echo "  longhorn-system not installed"
  fi
else
  echo "  Longhorn lab cluster not present, skipping"
fi

# ---------------------------------------------------------------------------
step "4/6 Remove the shared lesson's driver and snapshot API (wherever they are)"
for cluster in $CEPH_CLUSTER $LH_CLUSTER; do
  kind_has "$cluster" || continue
  reachable "$cluster" || continue
  if K "$cluster" get crd volumesnapshots.snapshot.storage.k8s.io >/dev/null 2>&1 \
     || K "$cluster" get deploy -n kube-system snapshot-controller >/dev/null 2>&1; then
    SS=https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.6.0
    K "$cluster" delete -f $SS/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml --ignore-not-found >/dev/null 2>&1
    K "$cluster" delete -f $SS/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml --ignore-not-found >/dev/null 2>&1
    K "$cluster" delete -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
                     -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
                     -f $SS/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml --ignore-not-found >/dev/null 2>&1
    echo "  $cluster: snapshot CRDs and controller removed"
  fi
  if K "$cluster" get statefulset csi-hostpathplugin >/dev/null 2>&1; then
    K "$cluster" delete statefulset csi-hostpathplugin csi-hostpath-socat --ignore-not-found >/dev/null 2>&1
    K "$cluster" delete service hostpath-service --ignore-not-found >/dev/null 2>&1
    K "$cluster" delete clusterrolebinding -l app.kubernetes.io/part-of=csi-driver-host-path --ignore-not-found >/dev/null 2>&1
    K "$cluster" delete clusterrole -l app.kubernetes.io/part-of=csi-driver-host-path --ignore-not-found >/dev/null 2>&1
    K "$cluster" delete csidriver hostpath.csi.k8s.io --ignore-not-found >/dev/null 2>&1
    echo "  $cluster: reference driver (csi-driver-host-path) removed"
  fi
done

# ---------------------------------------------------------------------------
step "5/6 Undo the node-side lab hacks (inside the nodes, before they are deleted)"
# Only for labs that are actually here: a lab whose cluster is gone has no node
# containers, and a lab you did not select must not be touched. Skipping that
# check is how an earlier version of this script detached the *other* lab's
# devices while "cleaning" a cluster that did not exist.
NODES_TO_CLEAN=()
[ "$want_ceph" = "1" ] && kind_has "$CEPH_CLUSTER" && NODES_TO_CLEAN+=("${CEPH_NODES[@]}")
[ "$want_lh" = "1" ]   && kind_has "$LH_CLUSTER"   && NODES_TO_CLEAN+=("${LH_NODES[@]}")
if [ "${#NODES_TO_CLEAN[@]}" -eq 0 ]; then
  echo "  nothing to clean: no selected lab cluster is present"
fi
for NODE in "${NODES_TO_CLEAN[@]}"; do
  if docker inspect "$NODE" >/dev/null 2>&1; then
    docker exec "$NODE" sh -c '
      umount /var/lib/longhorn 2>/dev/null
      for f in /var/lib/rook-osd/osd.img /var/lib/longhorn-disk.img; do
        for d in $(losetup -j "$f" 2>/dev/null | cut -d: -f1); do losetup -d "$d" 2>/dev/null; done
      done
      losetup -D 2>/dev/null
      rm -f /var/lib/rook-osd/osd.img /var/lib/longhorn-disk.img
    ' >/dev/null 2>&1 && echo "  $NODE: unmounted data paths, detached loop devices, removed backing files"
  fi
done
echo "  (/dev/loop* device-node files may survive inside a node's private /dev;"
echo "   they are meaningless without a backing device and vanish with the node.)"

# ---------------------------------------------------------------------------
step "6/6 Delete whichever lab clusters exist"
if [ "$KEEP_CLUSTERS" = "1" ]; then
  echo "  KEEP_CLUSTERS=1, leaving the clusters running"
else
  for cluster in $CEPH_CLUSTER $LH_CLUSTER; do
    case "$cluster" in
      "$CEPH_CLUSTER") [ "$want_ceph" = "1" ] || continue ;;
      "$LH_CLUSTER")   [ "$want_lh" = "1" ]   || continue ;;
    esac
    if kind_has "$cluster"; then
      cfg="$(kubeconfig_for "$cluster")"
      if [ -n "$cfg" ]; then
        kind delete cluster --name "$cluster" --kubeconfig "$cfg" >/dev/null 2>&1 \
          && echo "  $cluster deleted" || echo "  $cluster: kind reported an error while deleting"
      else
        kind delete cluster --name "$cluster" >/dev/null 2>&1 \
          && echo "  $cluster deleted" || echo "  $cluster: kind reported an error while deleting"
      fi
    else
      echo "  $cluster: not present"
    fi
  done
fi

step "leftovers worth knowing about"
LEFT=$(losetup -a 2>/dev/null | grep -c lost || true)
if [ "${LEFT:-0}" -gt 0 ]; then
  echo "  $LEFT stale (lost) loop devices from an earlier unclean teardown:"
  losetup -a 2>/dev/null | grep lost | sed 's/^/    /'
  echo "    harmless until reboot; detach with: sudo losetup -d <device>"
else
  echo "  no stale loop devices"
fi
cat <<'EOF'

Intentionally left in place
  * kernel modules loaded on the host: rbd, iscsi_tcp (gone at reboot)
  * docker images: ceph, longhorn, the CSI sidecars (docker image prune removes them)
  * the host's /sys mount flags: a kind node remounts only its own namespaces
EOF

#!/usr/bin/env bash
# cleanup.sh — remove both labs. Safe to re-run, and safe to run when only one of
# them exists.
#
# The two labs are independent, and they do not even share a substrate: the Ceph
# lab owns the kind cluster `csilab`, the Longhorn lab owns two qemu VMs in
# longhorn-lab/00-cluster-setup/. So this script *checks what is there* at every
# step instead of assuming a state:
#
#   * a cluster that does not exist is skipped, not an error
#   * a storage system that was never installed is skipped
#   * a teardown step that is already done is skipped
#   * the VMs are only touched if there are VMs
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
# A caveat on point 3: the detach `docker exec`s into the node, and a
# mount-namespace-level `losetup -D` does not always reach the host, so the run can
# end with stale devices anyway. The final section detects them on both the old
# (`lost`) and the new (`(deleted)`, empty device field) kernel reporting styles,
# detaches them if sudo is passwordless, and otherwise prints the command to run.
#
#   ./cleanup.sh                 # both labs
#   ./cleanup.sh ceph            # only the Ceph lab (the kind cluster)
#   ./cleanup.sh longhorn        # only the Longhorn lab (the VMs)
#   KEEP_CLUSTERS=1 ./cleanup.sh # uninstall Rook Ceph but keep the nodes/VMs
#                                # (Longhorn inside the VMs is left alone)
#
set -uo pipefail

WHICH="${1:-both}"
KEEP_CLUSTERS="${KEEP_CLUSTERS:-0}"

CEPH_CLUSTER="${CEPH_CLUSTER:-csilab}"
CEPH_NODES=(csilab-control-plane csilab-worker csilab-worker2)
VM_DIR="$(cd "$(dirname "$0")" && pwd)/longhorn-lab/00-cluster-setup"
# Workload namespaces on the Ceph lab's cluster. The Longhorn lab's namespace
# (lh-demo) lives inside the VMs and goes away with them in step 3.
NS_TO_PURGE=(ceph-demo csi-basics)

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

kind_has() { command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$1"; }
kubeconfig_for() {
  case "$1" in
    "$CEPH_CLUSTER") [ -f "$(dirname "$0")/.csi-lab.kubeconfig" ] && echo "$(cd "$(dirname "$0")" && pwd)/.csi-lab.kubeconfig" ;;
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
step "1/6 Delete the workloads in the Ceph lab cluster, if it exists"
for cluster in $CEPH_CLUSTER; do
  kind_has "$cluster" || { echo "  $cluster: not running, skipping"; continue; }
  reachable "$cluster" || { echo "  $cluster: not reachable with kubectl, skipping"; continue; }
  for ns in "${NS_TO_PURGE[@]}"; do
    if K "$cluster" get ns "$ns" >/dev/null 2>&1; then
      K "$cluster" delete ns "$ns" --wait=true --timeout=180s >/dev/null 2>&1 \
        && echo "  $cluster: deleted namespace $ns" \
        || echo "  $cluster: namespace $ns did not finish deleting"
    fi
  done
  for sc in rook-ceph-block rook-cephfs csi-hostpath-sc; do
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
step "3/6 Longhorn lab: the VMs"
VM_SH="$VM_DIR/vm.sh"
if [ "$want_lh" = "1" ]; then
  if [ -x "$VM_SH" ]; then
    running=0
    for role in server agent; do
      [ -f "$VM_DIR/qemu-$role.pid" ] && kill -0 "$(cat "$VM_DIR/qemu-$role.pid")" 2>/dev/null && running=$((running+1))
    done
    disks=$(ls "$VM_DIR"/disk-*.qcow2 2>/dev/null | wc -l)
    echo "  VMs running: $running   VM disks present: $disks"
    if [ "$running" = "0" ] && [ "$disks" = "0" ]; then
      echo "  nothing to clean: this lab's VMs do not exist"
    elif [ "$KEEP_CLUSTERS" = "1" ]; then
      # Keep the VMs but leave Longhorn itself intact: there is nothing outside the
      # VMs to clean, so this is a no-op by design.
      echo "  KEEP_CLUSTERS=1, leaving the VMs (and Longhorn inside them) alone"
    else
      "$VM_SH" destroy
    fi
  else
    echo "  no vm.sh found at $VM_SH, skipping"
  fi
else
  echo "  Longhorn lab not selected, skipping"
fi

step "4/6 Remove the shared lesson's driver and snapshot API (wherever they are)"
for cluster in $CEPH_CLUSTER; do
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
# Only kind nodes need this: the Longhorn lab's VMs are destroyed wholesale by
# vm.sh, disks and all, so there is no host-side state of theirs to undo.
[ "$want_ceph" = "1" ] && kind_has "$CEPH_CLUSTER" && NODES_TO_CLEAN+=("${CEPH_NODES[@]}")
if [ "${#NODES_TO_CLEAN[@]}" -eq 0 ]; then
  echo "  nothing to clean: the Ceph lab's cluster is not present"
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
step "6/6 Delete the Ceph lab's kind cluster"
if [ "$KEEP_CLUSTERS" = "1" ]; then
  echo "  KEEP_CLUSTERS=1, leaving the cluster running"
elif [ "$want_ceph" != "1" ]; then
  echo "  Ceph lab not selected, skipping"
elif kind_has "$CEPH_CLUSTER"; then
  cfg="$(kubeconfig_for "$CEPH_CLUSTER")"
  if [ -n "$cfg" ]; then
    kind delete cluster --name "$CEPH_CLUSTER" --kubeconfig "$cfg" >/dev/null 2>&1 \
      && echo "  $CEPH_CLUSTER deleted" || echo "  $CEPH_CLUSTER: kind reported an error while deleting"
  else
    kind delete cluster --name "$CEPH_CLUSTER" >/dev/null 2>&1 \
      && echo "  $CEPH_CLUSTER deleted" || echo "  $CEPH_CLUSTER: kind reported an error while deleting"
  fi
else
  echo "  $CEPH_CLUSTER: not present"
fi

step "leftovers worth knowing about"
# A loop device whose backing file was deleted inside a node that no longer exists
# stays attached in the HOST kernel. Detecting that took a fix: the classic marker
# is the status field reading `lost` — `/dev/loop0: [2049]:12345 (/path (deleted))`
# — but on newer kernels (7.2.3 here) the same condition prints an EMPTY device
# field instead, with no status word at all:
#
#   /dev/loop220: []: (/var/lib/longhorn-disk.img (deleted))
#
# Matching only on `lost` therefore finds nothing on a modern host, which is how
# this script used to print "no stale loop devices" while holding five.
stale_loops() {
  losetup -a 2>/dev/null | grep -E 'lost|\(deleted\)' || true
}
LEFT=$(stale_loops | grep -c . || true)
if [ "${LEFT:-0}" -gt 0 ]; then
  echo "  $LEFT stale loop devices: their backing file is gone, the host still holds them"
  stale_loops | sed 's/^/    /'
  if sudo -n true 2>/dev/null; then
    for dev in $(stale_loops | cut -d: -f1); do
      if sudo -n losetup -d "$dev" 2>/dev/null; then
        echo "    detached $dev"
      else
        echo "    could not detach $dev (still in use)"
      fi
    done
    echo "  remaining: $(stale_loops | grep -c . || echo 0)"
  else
    echo "    detaching needs root, which this script does not have; run:"
    echo "      sudo losetup -d $(stale_loops | cut -d: -f1 | tr '\n' ' ')"
  fi
  echo "    (they hold the unlinked backing file open, so its blocks stay allocated;"
  echo "     a reboot reclaims them, and so does the command above.)"
else
  echo "  no stale loop devices"
fi
cat <<'EOF'

Intentionally left in place
  * kernel modules loaded on the host: rbd (gone at reboot)
  * docker images: ceph, the CSI sidecars (docker image prune removes them)
  * the host's /sys mount flags: a kind node remounts only its own namespaces
  * longhorn-lab/00-cluster-setup/noble.img, the 600MB Ubuntu cloud image, which is
    reused by the next './vm.sh up' (delete it by hand to reclaim the space)
EOF

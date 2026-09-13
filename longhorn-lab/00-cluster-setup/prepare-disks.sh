#!/usr/bin/env bash
# prepare-disks.sh — the Longhorn lab's "hardware": a data path per node, and a
# working iscsid.
#
# Longhorn asks a node for exactly two things:
#
#   * a directory on an extent-based filesystem to keep replicas in
#     (default /var/lib/longhorn; ext4 or XFS only)
#   * a running iscsid, because the V1 data engine logs in to an iSCSI target to
#     expose a volume to its node
#
# Neither exists in a kind node, so both are simulated here — and the iscsid part
# is more than a simulation detail. How it is started decides whether Longhorn can
# talk to it at all; Lesson 01 shows the two states that fail and why.
#
# Loop devices are kernel-global. This lab uses 220+, so it can run alongside the
# Ceph lab's cluster, which uses 100/101.
#
# Idempotent: run it again after any node restart.
#
set -euo pipefail

LH_SIZE="${LH_SIZE:-5G}"
LH_PATH="/var/lib/longhorn"
LH_NODES=(lhslab-control-plane lhslab-worker lhslab-worker2)
declare -A LH_LOOP=([lhslab-control-plane]=220 [lhslab-worker]=221 [lhslab-worker2]=222)

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
node_sh() { docker exec "$1" sh -c "$2"; }

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user: this script only uses docker exec"; exit 1; }

targets=("$@")
[ "${#targets[@]}" -gt 0 ] || targets=("${LH_NODES[@]}")

for NODE in "${targets[@]}"; do
  if ! docker inspect "$NODE" >/dev/null 2>&1; then
    echo "!! no container named $NODE — is the lhslab cluster running?" >&2
    exit 1
  fi

  say "$NODE — kernel modules"
  node_sh "$NODE" 'modprobe iscsi_tcp && lsmod | grep -E "^iscsi_tcp"'

  say "$NODE — iSCSI daemon"
  # Longhorn's V1 data engine logs in to an iSCSI target with iscsiadm, and it
  # does so by entering a live iscsid process's namespaces:
  #     nsenter --mount=/host/proc/<iscsid pid>/ns/mnt --net=/host/proc/<iscsid pid>/ns/net ...
  # Two things have to be true for that to work, so this reports both instead of
  # claiming success:
  #
  #   * the socket unit must be listening, or iscsiadm cannot reach a daemon at
  #     all and says so:
  #         iscsiadm: can not connect to iSCSI daemon (111)!
  #   * a live iscsid process must exist, because that is the namespace Longhorn
  #     borrows. In a kind node the daemon is socket-activated and exits again
  #     once it has served, so this is usually 0 — and then the engine's next
  #     call runs against a dead PID:
  #         iscsiadm: read error (0/2), daemon died?
  #
  # Lesson 01 explains why even a live daemon is not enough here (the client ends
  # up in the pod's PID namespace), and what that means for Longhorn on kind.
  node_sh "$NODE" 'systemctl start iscsid.socket 2>/dev/null
    systemctl reset-failed iscsid 2>/dev/null
    systemctl start iscsid 2>/dev/null
    sleep 2
    echo -n "  iscsid.socket: "; systemctl is-active iscsid.socket 2>/dev/null
    echo -n "  listener on @ISCSIADM_ABSTRACT_NAMESPACE: "; ss -xl 2>/dev/null | grep -c ISCSIADM
    echo -n "  live iscsid processes: "; pgrep -x iscsid | wc -l'

  LH_IDX="${LH_LOOP[$NODE]:-}"
  [ -n "$LH_IDX" ] || { echo "!! no loop index mapped for $NODE" >&2; exit 1; }

  say "$NODE — Longhorn data path (${LH_PATH} on /dev/loop${LH_IDX}, ${LH_SIZE})"
  # Longhorn rejects a data path that is not on an extent-based filesystem, and
  # this workstation's root filesystem is btrfs, which Longhorn does not support.
  # Each node therefore gets its own ext4 on a loop device. Pointing Longhorn at a
  # plain directory would fail here for a real reason, not a lab reason.
  node_sh "$NODE" "
    set -e
    [ -f /var/lib/longhorn-disk.img ] || truncate -s ${LH_SIZE} /var/lib/longhorn-disk.img
    [ -b /dev/loop${LH_IDX} ] || mknod /dev/loop${LH_IDX} b 7 ${LH_IDX}
    LH_IMG=/var/lib/longhorn-disk.img
    CUR=\$(losetup -n -O BACK-FILE /dev/loop${LH_IDX} 2>/dev/null)
    if [ \"\$CUR\" = \"\$LH_IMG\" ]; then
      echo 'already attached to the right backing file'
    elif [ -n \"\$CUR\" ]; then
      losetup -d /dev/loop${LH_IDX} 2>/dev/null
      losetup /dev/loop${LH_IDX} \$LH_IMG
      echo re-attached, previous backing file was \$CUR
    else
      losetup /dev/loop${LH_IDX} \$LH_IMG
      echo 'loop device attached'
    fi
    if mountpoint -q ${LH_PATH}; then
      echo '${LH_PATH} already a mount point'
    else
      mkdir -p ${LH_PATH}
      blkid /dev/loop${LH_IDX} >/dev/null 2>&1 || mkfs.ext4 -q -F /dev/loop${LH_IDX}
      mount /dev/loop${LH_IDX} ${LH_PATH}
      echo 'mounted'
    fi
    findmnt -no FSTYPE,SOURCE,TARGET ${LH_PATH}
  "
done

say "summary"
for NODE in "${targets[@]}"; do
  printf '\n--- %s\n' "$NODE"
  node_sh "$NODE" 'findmnt -no FSTYPE,SOURCE,TARGET /var/lib/longhorn; echo -n "  iscsid processes: "; pgrep -x iscsid | wc -l'
done

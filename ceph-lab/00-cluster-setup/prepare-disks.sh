#!/usr/bin/env bash
# prepare-disks.sh — the Ceph lab's "hardware": one empty block device per
# storage node, and the kernel bits the CSI plugin needs.
#
# Ceph asks a node for very little: an empty block device that an OSD can claim,
# and a kernel that can map RBD images. A kind node has neither, so this script
# fakes the first and fixes up the second. Everything here is idempotent: run it
# again after a node restart.
#
#   ./prepare-disks.sh                 # both workers
#   ./prepare-disks.sh csilab-worker   # just one
#
set -euo pipefail

OSD_SIZE="${OSD_SIZE:-8G}"
OSD_NODES=(csilab-worker csilab-worker2)

# Loop devices are kernel-global: /dev/loop100 in worker 1 and /dev/loop100 in
# worker 2 are the same device. Each node therefore gets its own index, or two
# OSDs would end up sharing one backing file.
declare -A OSD_LOOP=([csilab-worker]=100 [csilab-worker2]=101)

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
node_sh() { docker exec "$1" sh -c "$2"; }

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user: this script only uses docker exec"; exit 1; }

targets=("$@")
[ "${#targets[@]}" -gt 0 ] || targets=("${OSD_NODES[@]}")

for NODE in "${targets[@]}"; do
  if ! docker inspect "$NODE" >/dev/null 2>&1; then
    echo "!! no container named $NODE — is the csilab cluster running?" >&2
    exit 1
  fi

  say "$NODE — kernel modules"
  # libceph/rbd are what the CSI node plugin needs to map a volume; loading them
  # here means the in-pod `modprobe rbd` finds them already present.
  node_sh "$NODE" 'modprobe rbd && lsmod | grep -E "^rbd"'

  say "$NODE — writable /sys"
  # kind mounts /sys read-only inside each node. The kernel RBD client (krbd)
  # registers a mapped image by writing /sys/bus/rbd/add, which fails on a
  # read-only /sys with "rbd: sysfs write failed ... Read-only file system" and
  # leaves every pod using an RBD volume in ContainerCreating. Rook's own CI
  # remounts /sys for exactly this reason. The remount stays inside the node's
  # mount namespace: remounting it back to ro in the node leaves the host at rw.
  node_sh "$NODE" 'findmnt -no OPTIONS /sys | grep -qw rw || mount -o remount,rw /sys; findmnt -no TARGET,OPTIONS /sys'

  say "$NODE — /dev/rbd* device nodes"
  # A kind node's /dev is its own private tmpfs, not the kernel's devtmpfs, so the
  # kernel's habit of creating /dev/rbd0 when an image is mapped does not reach
  # it. ceph-csi maps with `--options noudev` and then looks for /dev/rbd0, which
  # is why krbd volumes otherwise fail with:
  #     rbd: mapping succeeded but /dev/rbd0 is not accessible, is host /dev mounted?
  # Creating the (currently unmapped) nodes up front fixes that without
  # bind-mounting the host's entire /dev into the node. The major number is read
  # from /proc/devices rather than assumed.
  RBD_MAJOR=$(node_sh "$NODE" "awk '\$2 == \"rbd\" { print \$1 }' /proc/devices")
  if [ -n "$RBD_MAJOR" ]; then
    node_sh "$NODE" "
      set -e
      n=0
      while [ \$n -lt 8 ]; do
        [ -b /dev/rbd\$n ] || mknod /dev/rbd\$n b ${RBD_MAJOR} \$n
        n=\$((n+1))
      done
      ls -l /dev/rbd0
    "
  else
    echo "!! rbd is not registered in /proc/devices — run 'modprobe rbd' first"
    exit 1
  fi

  OSD_IDX="${OSD_LOOP[$NODE]:-}"
  [ -n "$OSD_IDX" ] || { echo "!! no loop index mapped for $NODE" >&2; exit 1; }

  say "$NODE — fake OSD disk (/dev/loop${OSD_IDX}, ${OSD_SIZE})"
  node_sh "$NODE" "
    set -e
    mkdir -p /var/lib/rook-osd
    [ -f /var/lib/rook-osd/osd.img ] || truncate -s ${OSD_SIZE} /var/lib/rook-osd/osd.img
    [ -b /dev/loop${OSD_IDX} ] || mknod /dev/loop${OSD_IDX} b 7 ${OSD_IDX}
    OSD_IMG=/var/lib/rook-osd/osd.img
    CUR=\$(losetup -n -O BACK-FILE /dev/loop${OSD_IDX} 2>/dev/null)
    if [ \"\$CUR\" = \"\$OSD_IMG\" ]; then
      echo 'already attached to the right backing file'
    elif [ -n \"\$CUR\" ]; then
      losetup -d /dev/loop${OSD_IDX} 2>/dev/null
      losetup /dev/loop${OSD_IDX} \$OSD_IMG
      echo re-attached, previous backing file was \$CUR
    else
      losetup /dev/loop${OSD_IDX} \$OSD_IMG
      echo 'attached'
    fi
    losetup -l | grep loop${OSD_IDX}
  "
  # Why the check above is not paranoia: a loop device can outlive its backing
  # file and stay attached to a deleted inode - that is what "(deleted)" in
  # `losetup` means. Asking only "is it attached?" would then report success while
  # the OSD points at nothing at all.
  # Do NOT wipe device signatures here. A version of this script did, and running
  # it against a cluster that already had a Ceph OSD on the device destroyed that
  # OSD's BlueStore metadata (the OSD pod then failed in its expand-bluefs init
  # container, which looks like a kind problem and is not). A brand-new backing
  # file needs no wipe, so wiping is opt-in.
  if [ "${WIPE_OSD_DEVICE:-0}" = "1" ]; then
    node_sh "$NODE" "wipefs -a /dev/loop${OSD_IDX} >/dev/null 2>&1 || true"
    echo "wiped signatures on /dev/loop${OSD_IDX} because WIPE_OSD_DEVICE=1"
  else
    echo "left /dev/loop${OSD_IDX} signatures alone (WIPE_OSD_DEVICE=1 blanks it on purpose)"
  fi
done

say "summary"
for NODE in "${targets[@]}"; do
  printf '\n--- %s\n' "$NODE"
  node_sh "$NODE" 'losetup -l | grep -E "loop1(00|01)" ; echo; ls -l /dev/rbd0'
done

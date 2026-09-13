#!/usr/bin/env bash
# prepare-disks.sh — give the kind "nodes" the things a storage system expects.
#
# On real hardware the two storage systems in this course ask for very little:
#
#   * a raw, empty block device per storage node   (Ceph OSDs)
#   * a mount point with free space                (Longhorn's data path)
#   * the iscsi_tcp kernel module + a running iscsid (Longhorn's engine)
#   * the rbd kernel module                        (Ceph's CSI node plugin)
#
# A kind "node" is a privileged container built from kindest/node. It has none
# of the first two, so this script fakes them with loop devices and says so out
# loud. Everything here is idempotent: run it again after a node restart.
#
#   ./prepare-disks.sh          # all nodes
#   ./prepare-disks.sh csilab-worker   # just one node
#
set -euo pipefail

OSD_SIZE="${OSD_SIZE:-8G}"      # fake disk for a Ceph OSD
LH_SIZE="${LH_SIZE:-5G}"        # fake disk for Longhorn's data path
LH_PATH="/var/lib/longhorn"     # Longhorn's default data path

# Every node gets a Longhorn data path, because Longhorn counts *nodes*: a
# volume with 3 replicas needs 3 nodes with a usable disk, and one of them is the
# control-plane here. Only the two workers get a raw disk for Ceph, which is the
# point of Lesson 02 — an OSD wants an empty block device, nothing else.
ALL_NODES=(csilab-control-plane csilab-worker csilab-worker2)

# Loop devices are a *kernel*-global resource: /dev/loop100 in worker 1 and
# /dev/loop100 in worker 2 are the same device. Each node therefore gets its own
# index, or two OSDs would end up fighting over one backing file. A node missing
# from OSD_LOOP simply gets no Ceph disk.
declare -A OSD_LOOP=([csilab-worker]=100 [csilab-worker2]=101)
declare -A LH_LOOP=([csilab-control-plane]=112 [csilab-worker]=110 [csilab-worker2]=111)

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
node_sh() { docker exec "$1" sh -c "$2"; }

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user: this script only uses docker exec"; exit 1; }

targets=("$@")
[ "${#targets[@]}" -gt 0 ] || targets=("${ALL_NODES[@]}")

for NODE in "${targets[@]}"; do
  if ! docker inspect "$NODE" >/dev/null 2>&1; then
    echo "!! no container named $NODE — is the csilab cluster running?" >&2
    exit 1
  fi

  say "$NODE — kernel modules"
  # kindest/node ships an empty /lib/modules (the kernel belongs to the host);
  # kind-config.yaml mounts the host's /lib/modules read-only so this can work.
  node_sh "$NODE" 'modprobe rbd && modprobe iscsi_tcp && lsmod | grep -E "^(rbd|iscsi_tcp)"'

  say "$NODE — writable /sys"
  # kind mounts /sys read-only inside each node. Ceph's CSI node plugin maps RBD
  # images with the kernel client (krbd), which registers the new device by
  # writing /sys/bus/rbd/add — on a read-only /sys that fails with
  # "rbd: sysfs write failed ... Read-only file system" and every pod using an
  # RBD volume hangs in ContainerCreating. Rook's own CI remounts /sys for
  # exactly this reason. The remount is confined to the node's mount namespace
  # (checked both ways: remounting ro inside the node leaves the host at rw).
  node_sh "$NODE" 'findmnt -no OPTIONS /sys | grep -qw rw || mount -o remount,rw /sys; findmnt -no TARGET,OPTIONS /sys'

  say "$NODE — /dev/rbd* device nodes"
  # A kind node's /dev is its own private tmpfs, not the kernel's devtmpfs, so
  # the kernel's habit of auto-creating /dev/rbd0 when an image is mapped does
  # not reach it. ceph-csi maps with `--options noudev` and then looks for
  # /dev/rbd0, which is why krbd volumes fail with:
  #     rbd: mapping succeeded but /dev/rbd0 is not accessible, is host /dev mounted?
  # Creating the (currently unmapped) device nodes up front fixes it without
  # bind-mounting the host's entire /dev into the node. Major 251 is what this
  # kernel uses for rbd; read it rather than assuming.
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

  say "$NODE — iSCSI daemon"
  # Longhorn's storage engine logs into an iSCSI target with `iscsiadm`, and
  # `iscsiadm` talks to the iscsid *daemon* over a socket. Starting the bare
  # `iscsid` binary is not enough: it leaves iscsiadm unable to reach the daemon,
  # and every Longhorn volume then sits in `attaching` forever while the engine
  # logs
  #     iscsiadm: can not connect to iSCSI daemon (111)!
  #     iscsiadm: Could not login to [...]: initiator reported error (20 - could not connect to iscsid)
  # `iscsid.startup` in /etc/iscsi/iscsid.conf is `/bin/systemctl start
  # iscsid.socket`, which is why iscsiadm also tries D-Bus and reports
  # "Failed to connect to bus: No data available" on the way to failing.
  # kind nodes run systemd as PID 1 and ship both units, so start the unit.
  #
  # Note: `systemctl is-active iscsid` still reports "inactive" afterwards - it is
  # socket-activated - so this checks the process, not systemd's opinion.
  node_sh "$NODE" 'systemctl start iscsid 2>/dev/null; sleep 1; pgrep -x iscsid >/dev/null && echo "iscsid running" || echo "!! iscsid NOT running"'

  LH_IDX="${LH_LOOP[$NODE]:-}"
  [ -n "$LH_IDX" ] || { echo "!! no loop index mapped for $NODE" >&2; exit 1; }

  OSD_IDX="${OSD_LOOP[$NODE]:-}"
  if [ -n "$OSD_IDX" ]; then
    say "$NODE — fake OSD disk (/dev/loop${OSD_IDX}, ${OSD_SIZE})"
    node_sh "$NODE" "
      set -e
      mkdir -p /var/lib/rook-osd
      [ -f /var/lib/rook-osd/osd.img ] || truncate -s ${OSD_SIZE} /var/lib/rook-osd/osd.img
      [ -b /dev/loop${OSD_IDX} ] || mknod /dev/loop${OSD_IDX} b 7 ${OSD_IDX}
      if losetup /dev/loop${OSD_IDX} >/dev/null 2>&1; then
        echo 'already attached'
      else
        losetup /dev/loop${OSD_IDX} /var/lib/rook-osd/osd.img
        echo 'attached'
      fi
      losetup -l | grep loop${OSD_IDX}
    "
    # DO NOT wipe device signatures here by default. Doing exactly that was a bug
    # worth recording: re-running this script against a cluster that already had
    # Ceph on it wiped a *live* OSD's BlueStore metadata off /dev/loop100. The next
    # OSD pod then failed in its `expand-bluefs` init container, because
    # ceph-bluestore-tool was handed a device that no longer looked like an OSD -
    # which reads exactly like "Ceph is broken on kind" until `wipefs /dev/loop100`
    # prints nothing at all.
    #
    # A brand-new backing file needs no wipe, so this is opt-in: use it only when
    # you deliberately want a blank device (e.g. re-provisioning a failed OSD).
    if [ "${WIPE_OSD_DEVICE:-0}" = "1" ]; then
      node_sh "$NODE" "wipefs -a /dev/loop${OSD_IDX} >/dev/null 2>&1 || true"
      echo "wiped signatures on /dev/loop${OSD_IDX} because WIPE_OSD_DEVICE=1"
    else
      echo "left /dev/loop${OSD_IDX} signatures alone (WIPE_OSD_DEVICE=1 blanks it on purpose)"
    fi
  else
    say "$NODE — no Ceph disk"
    echo "not a Ceph storage node (only the workers get an OSD device)"
  fi

  say "$NODE — Longhorn data path (${LH_PATH} on /dev/loop${LH_IDX}, ${LH_SIZE})"
  # Longhorn does NOT accept just any directory: its disk must sit on an
  # extent-based filesystem (ext4 or XFS). This workstation's root filesystem is
  # btrfs, and kind gives each node a slice of it, so pointing Longhorn straight
  # at /var/lib/longhorn would fail for a real reason. Formatting our own ext4 on
  # top of the loop device is what makes the data path legitimate.
  node_sh "$NODE" "
    set -e
    [ -f /var/lib/longhorn-disk.img ] || truncate -s ${LH_SIZE} /var/lib/longhorn-disk.img
    [ -b /dev/loop${LH_IDX} ] || mknod /dev/loop${LH_IDX} b 7 ${LH_IDX}
    if losetup /dev/loop${LH_IDX} >/dev/null 2>&1; then
      echo 'loop device already attached'
    else
      losetup /dev/loop${LH_IDX} /var/lib/longhorn-disk.img
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
    df -h ${LH_PATH} | tail -1
  "
done

say "summary"
for NODE in "${targets[@]}"; do
  printf '\n--- %s\n' "$NODE"
  node_sh "$NODE" 'losetup -l | tail -n +2; echo; df -h /var/lib/longhorn | tail -1; pgrep -x iscsid >/dev/null && echo "iscsid: running" || echo "iscsid: NOT running"'
done

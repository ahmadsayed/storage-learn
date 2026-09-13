#!/usr/bin/env bash
# vm.sh — the Longhorn lab's cluster: two real VMs running k3s.
#
# Why VMs and not kind: Longhorn needs a real node. Its data engine drives iSCSI
# through iscsid, and its disk accounting resolves the data path to the filesystem
# *underneath* it — which inside a kind node is the host's filesystem rather than
# the one you mounted. Lesson 01 has the whole story, including what it looks like
# when it goes wrong. On a real node none of that is exotic: iscsid is an ordinary
# systemd service and /var/lib/longhorn is an ordinary ext4 directory.
#
# No host root is needed. qemu runs as your user with KVM, each VM reaches the
# internet through qemu's user-mode networking, and the two VMs are wired to each
# other over a multicast socket.
#
#   ./vm.sh up          # download the image if needed, build both VMs, fetch kubeconfig
#   ./vm.sh status      # what is running
#   ./vm.sh ssh server|agent -- <command>
#   ./vm.sh kubeconfig  # (re)fetch k3s kubeconfig into ./k3s.yaml
#   ./vm.sh down        # stop both VMs (their disks keep their state)
#   ./vm.sh destroy     # stop them and delete the disks
#
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$DIR/noble.img"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
KEY="$DIR/labkey"
MC="230.0.0.1:1234"                 # inter-VM L2; no root, no bridge, no tap
SERVER_IP=192.168.76.10
AGENT_IP=192.168.76.11

vm_ip()  { [ "$1" = server ] && echo "$SERVER_IP" || echo "$AGENT_IP"; }
vm_mac() { [ "$1" = server ] && echo "52:54:00:76:00:10" || echo "52:54:00:76:00:11"; }
vm_ssh() { [ "$1" = server ] && echo 2222 || echo 2223; }
vm_api() { [ "$1" = server ] && echo 6443 || echo 6444; }

ssh_vm() {
  local role="$1"; shift
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR -p "$(vm_ssh "$role")" lab@127.0.0.1 "$@"
}

make_keys() { [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"; }

make_seed() {
  local role="$1" token="${2:-}" ip mac k3s_exec work
  ip="$(vm_ip "$role")"; mac="$(vm_mac "$role")"
  case "$role" in
    server) k3s_exec="server --node-ip $ip --flannel-iface intervm --tls-san $ip --tls-san 127.0.0.1 --write-kubeconfig-mode 644 --disable traefik --disable servicelb" ;;
    agent)  k3s_exec="agent --server https://$SERVER_IP:6443 --token $token --node-ip $ip --flannel-iface intervm" ;;
  esac

  work="$(mktemp -d)"
  cat > "$work/user-data" <<EOF
#cloud-config
hostname: k3s-$role
users:
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
package_update: true
packages:
  - open-iscsi      # Longhorn's engine drives iSCSI through iscsid
  - nfs-common      # needed for RWX volumes, which Longhorn serves over NFS
  - curl
write_files:
  # The second NIC is the multicast link between the VMs. Pin it by MAC so its
  # name is predictable, and leave the first NIC on DHCP for internet access.
  - path: /etc/netplan/60-intervm.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          intervm:
            match:
              macaddress: "$mac"
            set-name: intervm
            dhcp4: false
            addresses: [$ip/24]
runcmd:
  # Renaming the second NIC briefly takes the first one's DHCP lease with it, so
  # apply twice; then wait for the internet before installing k3s, or the install
  # fails on a network race with nothing but a missing service to show for it.
  - [sh, -c, "netplan apply; sleep 10; netplan apply"]
  - [systemctl, enable, --now, iscsid]
  - [sh, -c, "modprobe iscsi_tcp"]
  - [sh, -c, "for i in \$(seq 1 40); do curl -sf -o /dev/null https://get.k3s.io && break; sleep 5; done; curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='$k3s_exec' sh -"]
EOF
  printf 'instance-id: k3s-%s\nlocal-hostname: k3s-%s\n' "$role" "$role" > "$work/meta-data"
  genisoimage -quiet -output "$DIR/seed-$role.iso" -volid cidata -joliet -rock \
    "$work/user-data" "$work/meta-data"
  rm -rf "$work"
}

start_vm() {
  local role="$1"
  # Only create the overlay the first time: recreating it on a restart would
  # silently reinstall the node, which is not what "restart the node" means.
  [ -f "$DIR/disk-$role.qcow2" ] || qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DIR/disk-$role.qcow2" 20G
  rm -f "$DIR/qemu-$role.pid"          # a stale pidfile makes qemu refuse to start
  if ! qemu-system-x86_64 \
      -machine q35,accel=kvm -cpu host -smp 2 -m 1792 \
      -drive file="$DIR/disk-$role.qcow2",if=virtio,cache=unsafe \
      -drive file="$DIR/seed-$role.iso",media=cdrom,readonly=on \
      -netdev user,id=n0,hostfwd=tcp::$(vm_ssh "$role")-:22,hostfwd=tcp::$(vm_api "$role")-:6443 \
      -device virtio-net-pci,netdev=n0 \
      -netdev socket,id=n1,mcast=$MC \
      -device virtio-net-pci,netdev=n1,mac=$(vm_mac "$role") \
      -display none -serial file:"$DIR/console-$role.log" \
      -daemonize -pidfile "$DIR/qemu-$role.pid"; then
    echo "!! qemu failed to start the $role VM — last console lines:" >&2
    tail -5 "$DIR/console-$role.log" >&2
    exit 1
  fi
  echo "  $role VM started (ssh 127.0.0.1:$(vm_ssh "$role"), api 127.0.0.1:$(vm_api "$role"))"
}

wait_ssh() {
  local role="$1" i
  for i in $(seq 1 60); do
    ssh_vm "$role" true >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}

wait_k3s_nodes() {
  local want="$1" i n
  for i in $(seq 1 90); do
    n=$(KUBECONFIG="$DIR/k3s.yaml" kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')
    [ "$n" -ge "$want" ] && return 0
    sleep 10
  done
  return 1
}

fetch_kubeconfig() {
  ssh_vm server 'sudo cat /etc/rancher/k3s/k3s.yaml' \
    | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$(vm_api server)#; s#https://${SERVER_IP}:6443#https://127.0.0.1:$(vm_api server)#; s#https://0.0.0.0:6443#https://127.0.0.1:$(vm_api server)#" \
    > "$DIR/k3s.yaml"
  echo "  kubeconfig: export KUBECONFIG=$DIR/k3s.yaml"
}

case "${1:-}" in
up)
  make_keys
  [ -f "$BASE" ] || { echo "== downloading the Ubuntu cloud image (~600MB, once)"; curl -sL -o "$BASE" "$IMAGE_URL"; }
  echo "== server VM"
  make_seed server
  start_vm server
  wait_ssh server || { echo "!! the server VM never came up; see $DIR/console-server.log" >&2; exit 1; }
  echo "  waiting for cloud-init to install k3s (a few minutes)"
  for i in $(seq 1 60); do ssh_vm server 'cloud-init status 2>/dev/null | grep -q done' && break; sleep 10; done
  fetch_kubeconfig
  wait_k3s_nodes 1 || { echo "!! the k3s server did not become Ready" >&2; exit 1; }
  TOKEN=$(ssh_vm server 'sudo cat /var/lib/rancher/k3s/server/node-token' | tr -d '\r')
  echo "== agent VM"
  make_seed agent "$TOKEN"
  start_vm agent
  wait_ssh agent || { echo "!! the agent VM never came up; see $DIR/console-agent.log" >&2; exit 1; }
  for i in $(seq 1 60); do ssh_vm agent 'cloud-init status 2>/dev/null | grep -q done' && break; sleep 10; done
  wait_k3s_nodes 2 || { echo "!! only one node joined; check 'vm.sh ssh agent -- journalctl -u k3s-agent'" >&2; exit 1; }
  echo "== cluster ready"
  KUBECONFIG="$DIR/k3s.yaml" kubectl get nodes -o wide
  ;;

status)
  for role in server agent; do
    if [ -f "$DIR/qemu-$role.pid" ] && kill -0 "$(cat "$DIR/qemu-$role.pid")" 2>/dev/null; then
      echo "  $role VM: running (pid $(cat "$DIR/qemu-$role.pid"))"
    else
      echo "  $role VM: not running"
    fi
  done
  [ -f "$DIR/k3s.yaml" ] && KUBECONFIG="$DIR/k3s.yaml" kubectl get nodes 2>/dev/null
  ;;

ssh)
  role="${2:-server}"; shift 2; [ "${1:-}" = "--" ] && shift
  ssh_vm "$role" "$@"
  ;;

kubeconfig) fetch_kubeconfig ;;

start)
  role="${2:-server}"; shift 2 2>/dev/null || true
  make_keys
  [ -f "$DIR/seed-$role.iso" ] || { echo "!! no seed for $role — run 'vm.sh up' once to create the VMs" >&2; exit 1; }
  start_vm "$role"
  ;;

stop)
  for role in server agent; do
    if [ -f "$DIR/qemu-$role.pid" ]; then
      kill "$(cat "$DIR/qemu-$role.pid")" 2>/dev/null && echo "  stopped $role VM"
      rm -f "$DIR/qemu-$role.pid"
    fi
  done
  ;;

down)
  for role in server agent; do
    if [ -f "$DIR/qemu-$role.pid" ]; then
      pid="$(cat "$DIR/qemu-$role.pid")"
      kill "$pid" 2>/dev/null && echo "  stopped $role VM (pid $pid); its disk keeps its state"
      rm -f "$DIR/qemu-$role.pid"
    fi
  done
  ;;

destroy)
  for role in server agent; do
    [ -f "$DIR/qemu-$role.pid" ] && kill "$(cat "$DIR/qemu-$role.pid")" 2>/dev/null
    rm -f "$DIR/qemu-$role.pid" "$DIR/disk-$role.qcow2" "$DIR/seed-$role.iso" \
          "$DIR/console-$role.log"
  done
  rm -f "$DIR/k3s.yaml"
  echo "  VMs and their disks removed (the downloaded cloud image is kept for next time;"
  echo "  delete $BASE if you want that gone too)"
  ;;

*) sed -n '2,24p' "$0"; exit 2 ;;
esac

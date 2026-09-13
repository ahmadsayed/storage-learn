# Design: move the Ceph lab from kind to qemu/k3s VMs

Date: 2026-09-13
Status: approved in brainstorming; pending implementation plan

## Goal

The Ceph lab currently runs on a kind cluster (`csilab`) and the Longhorn lab on
two qemu/k3s VMs built by `vm.sh`. This change moves the Ceph lab onto the same
VM substrate — same tooling, **separate VMs** — so the whole course has one
substrate and zero host root requirements. kind, Docker, and every kind-specific
lab hack leave the course.

Decisions already made with the user:

- **Same tooling, separate VMs.** Ceph gets its own two-VM k3s cluster; the labs
  remain independent on purpose (isolated failure drills, side-by-side runs).
- **kind is dropped entirely.** The shared CSI-fundamentals lesson migrates to
  the Ceph lab's VMs.
- **3 GB RAM per Ceph VM.** Longhorn VMs raised to 2 GB so sizing is per-lab
  config. (Host constraint: 15 GB total RAM; the "don't run both labs at once"
  guidance stays.)
- **Shared lib + thin per-lab wrapper** for the VM tooling. No forked copies of
  the qemu/k3s machinery.

## Architecture

### VM substrate

- `vm-lib.sh` at repository root holds all shared machinery: cloud-init seed
  generation, qemu launch, SSH helpers, k3s readiness waits, kubeconfig fetch,
  and the `up|status|ssh|kubeconfig|start|stop|down|destroy` subcommands.
- Each lab keeps a thin `00-cluster-setup/vm.sh` that sets per-lab config and
  sources `../../vm-lib.sh`:

  | Setting | Longhorn lab | Ceph lab |
  |---------|-------------|----------|
  | Hostnames | `k3s-server`, `k3s-agent` | `ceph-server`, `ceph-agent` |
  | RAM per VM | 2 GB (`-m 2048`) | 3 GB (`-m 3072`) |
  | Host SSH forwards | 2222 / 2223 | 2242 / 2243 |
  | Host API forwards | 6443 / 6444 | 6453 / 6454 |
  | Multicast link | `230.0.0.1:1234` | `230.0.0.2:1234` |
  | Guest IPs | 192.168.76.10 / .11 | 192.168.77.10 / .11 |
  | Extra disk | none | `disk-osd-<role>.qcow2`, 20 GB → `/dev/vdb` |
  | cloud-init packages | open-iscsi, nfs-common, curl | curl |
  | cloud-init runcmd extras | iscsid enable + `modprobe iscsi_tcp` | `modprobe rbd` |

- `vm.sh` keeps resolving its own directory, so every existing Longhorn doc
  command keeps working unchanged.
- The guest kernel is Ubuntu noble's 6.8 (`6.8.0-139-generic` as recorded).

### What disappears

- `ceph-lab/00-cluster-setup/kind-config.yaml` and `prepare-disks.sh` (deleted).
- `00-csi-fundamentals` loses all `csilab-*` / `docker exec` references.
- `cleanup.sh` loses every kind branch: no `kind delete`, no node-side loop
  detach, no stale-loop detection. Both labs reduce to "optionally uninstall the
  storage system, then `vm.sh destroy`".
- Top-level README loses the Docker/kind requirements and the stale-loop
  known-limit block; requirements become qemu/KVM/genisoimage + kubectl/helm/git.

## The Ceph lab on VMs

### Lesson 00 (`ceph-lab/00-cluster-setup/`)

Becomes a mirror of the Longhorn lesson 00: `./vm.sh up`, verify devtmpfs/udev
are real, `lsblk` shows `/dev/vdb` empty, untaint `ceph-server` (2-node lab; the
control plane must run mon/mgr and demo pods). All 🧪 Lab Hack callouts are
removed — the production equivalent is now simply what the lab does.

### Lesson 01 (`ceph-lab/01-rook-ceph/`)

Flow unchanged: operator (Rook v1.20.7) → `CephCluster` → block pool → RBD
volume → CephFS RWX. Changes:

- `ROOK_CEPH_ALLOW_LOOP_DEVICES` step and callout deleted — real disk.
- Devices are `vdb` per node (explicit per-node naming stays as hygiene).
- The "Rook inventories your real NVMe" story is gone; replaced by the point
  that a VM can only see its own disks — the safer substrate is the story.
- Guest kernel 6.8 < 7.0, so `cluster.yaml` gains
  `security.cephx.csi.keyType: aes` per Rook's own `cluster-test.yaml` guidance
  for older kernels. The AUTH_INSECURE_KEYS mute passage is rewritten to match
  whatever the re-recorded `ceph status` actually shows.
- The kind-only failure mode (`/dev/rbd0 is not accessible`) and the
  `mknod /dev/rbdN` production-note row are removed; `/dev/rbd0` appears via
  devtmpfs like on any real node.

### Lesson 02 (`ceph-lab/02-day2/`)

Expansion, snapshot, restore unchanged. Failure drill changes:

- `docker stop csilab-worker` → `../00-cluster-setup/vm.sh stop agent` (the node
  holding one OSD really disappears).
- The wipefs-accident section (its vehicle, `prepare-disks.sh`, is gone) becomes
  a deliberate exercise after clean recovery: wipe `vdb`, watch the OSD fail,
  replace it (`ceph osd out/crush remove/auth del/rm`, delete the OSD
  deployment, re-prepare). Same "an OSD is a device plus metadata" lesson,
  taught on purpose.

## CSI fundamentals migration (`00-csi-fundamentals/`)

Pedagogy untouched; substrate plumbing changes:

- `nodeSelector` pins: `csilab-worker` → `ceph-agent`.
- Step 1: `docker exec … mkdir` → `vm.sh ssh agent -- 'sudo mkdir -p …'`.
- Step 3: k3s' built-in class is `local-path (default)` (same
  `rancher.io/local-path` provisioner, same "dynamic but not CSI" point); the PV
  hostPath becomes k3s' `/var/lib/rancher/k3s/storage/…`.
- Hostpath reference driver install flow unchanged (verify deploy dir vs k3s
  v1.36 during recording).
- Intro/outro wording moves from "kind cluster" to "the Ceph lab's cluster".
- All expected outputs re-recorded.

## Docs, cleanup, evidence

- **Everything is re-executed and re-recorded.** Per `.storage-lab/STYLE.md`,
  no output is written that wasn't run. Fresh transcripts replace the kind-era
  files in `.storage-lab/evidence/`; READMEs are written from the transcripts.
- Top-level `README.md`: lab tables, requirements (drop Docker/kind; ~6 GB for
  the Ceph lab; don't run both labs at once on a 15 GB machine), cleanup
  section, and the stale-loop known-limit block are rewritten. The
  Ceph-vs-Longhorn comparison table loses "on kind" qualifiers; the "Longhorn
  does not support kind" rationale stays — it is why the course is on VMs.
- `cleanup.sh` rewritten as described above; stale-loop detection removed
  (nothing creates loop devices anymore).
- `.storage-lab/STYLE.md` lab-facts section updated (no kind facts; VM facts
  for both labs; the kubectl wrapper `.storage-lab/k` repins
  `KUBECONFIG` to `ceph-lab/00-cluster-setup/k3s.yaml`).

## Error handling / risks

- **RAM pressure**: 2×3 GB Ceph VMs + desktop load on a 15 GB host is tight.
  Mitigation: docs keep "park the other lab"; vm-lib keeps qemu `-m` per lab.
- **OSD prepare on `vdb`**: the virtio disk must be truly empty; cloud-init does
  not touch it. Verified during recording via the OSD-prepare logs.
- **k3s minor vs hostpath deploy dir**: if `deploy/kubernetes-1.35` rejects
  v1.36, record the closest supported dir and say so in the lesson.
- **The Longhorn lab must not regress**: after vm-lib extraction, the Longhorn
  lab is rebuilt from scratch and its lesson re-run green before the Ceph work
  is recorded.

## Testing / verification

The deliverable is both labs green end-to-end, from scratch, on VMs:

1. `longhorn-lab/.../vm.sh up` → lesson 01 passes (install, mount, durability,
   node kill, recovery) with the shared lib.
2. `ceph-lab/.../vm.sh up` → fundamentals passes (four-volume table,
   snapshot/restore) → lesson 01 (`HEALTH_OK`, `/dev/rbd0` mount, RWX) →
   lesson 02 (expansion, snapshot/restore, node kill, degraded reads, recovery,
   disk replacement).
3. Both labs running side by side once (port/mcast isolation check), then
   `cleanup.sh` leaves no host state behind.
4. Doc sweep: no `kind`/`docker exec`/`csilab` references outside git history;
   every relative link resolves.

## Out of scope

- RGW/object storage, erasure coding, multi-monitor quorum (course already
  scopes these out).
- Changing the Longhorn lab's lesson content beyond vm.sh invocation paths.
- CI/automation for the labs.

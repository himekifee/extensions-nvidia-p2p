# Talos NVIDIA P2P System Extensions

Fork of [`siderolabs/extensions`](https://github.com/siderolabs/extensions) used to build and test NVIDIA peer-to-peer (P2P) GPU memory support on Talos Linux.

The stock Talos NVIDIA open-source driver modules ship without PCIe P2P exposed for this RTX 5090 test topology. This fork patches the open GPU kernel modules with the [aikitoria P2P donor patch](https://github.com/aikitoria/open-gpu-kernel-modules/tree/595.58.03-p2p) on top of its native NVIDIA 595.58.03 production base, keeps the same-key kernel/module build plumbing required for Talos `v1.13.0` / kernel `6.18.24-talos`, and can force NVIDIA RM P2P exposure through `NVreg_RegistryDwords` in `nvidia-gpu/nvidia-modules-p2p/pkg/production/files/nvidia.conf`. Everything else (userspace toolkit, container runtime, glibc, etc.) stays on stock official Talos production artifacts for the 595 family.

Current v1.13/595 status: capability exposure is not sufficient evidence of correctness. A deployment may show:

- `nvidia-smi topo -p2p r` = `OK`
- `cuDeviceCanAccessPeer` = `1` in both directions
- `cuCtxEnablePeerAccess` = `CUDA_SUCCESS` in both directions
- `p2pBandwidthLatencyTest` = high peer bandwidth

and still corrupt peer data on Talos. Always validate with the custom integrity probe in `p2p/`; bandwidth-only samples are not correctness tests.

Latest isolation result: Arch Linux 6.19.11 with NVIDIA 595.58.03 passes the integrity probe on the same Proxmox host and also when its disk is booted on the Talos VM's Gigabyte RTX 5090 passthrough path. VM199 also passes with both Proxmox `viommu=intel` and guest `intel_iommu=on iommu=pt` removed. The remaining failure is therefore not explained by vIOMMU, guest IOMMU flags/groups, ACS, BAR1 size alone, the Gigabyte cards, or the physical host PCIe path by themselves.

## Current Target Versions

| Component | Version / Pin |
|---|---|
| Talos Linux | v1.13.0 |
| Kubernetes | v1.36.0 |
| NVIDIA open driver (production) | 595.58.03 |
| NVIDIA container toolkit (production) | 595.58.03-v1.19.0 |
| P2P donor patch base | aikitoria 595.58.03-p2p, kept on the donor-native 595.58.03 base |
| Custom artifact publish state | Pending branch publish for `v1.13.0` |

Full version matrix with digests, abort conditions, and verification commands: [`docs/release-matrix.yaml`](docs/release-matrix.yaml).

## What This Fork Changes

**Custom** (P2P-specific):
- `nvidia-gpu/nvidia-modules-p2p/` ... patched NVIDIA open kernel modules with P2P support
- `kernel/` ... local kernel prepare/build stages (imported from `siderolabs/pkgs`) for same-key module signing
- `hack/p2p/` ... build, verification, and installer scripts
- `docs/release-matrix.yaml` ... pinned version matrix for the custom build
- `PROJECT.yaml` ... metadata describing the custom surface area

**Modified upstream files** (build plumbing):
- `.kres.yaml`, `Makefile`, `Pkgfile` ... custom build target registration and kernel/toolchain version pins

**Untouched upstream**:
Everything else. The full upstream `siderolabs/extensions` tree is preserved: `container-runtime/`, `drivers/`, `drm/`, `dvb/`, `firmware/`, `guest-agents/`, `misc/`, `network/`, `nvidia-gpu/nvidia-modules/`, `nvidia-gpu/nonfree/`, `nvidia-gpu/nvidia-container-toolkit/`, `power/`, `storage/`, `tools/`, `examples/`, `reproducibility/`, and `internal/`.

## Runtime P2P Forcing / Diagnostic Setting

The current production P2P extension forces NVIDIA RM to expose PCIe P2P at module load time:

```conf
options nvidia NVreg_RegistryDwords="ForceP2P=17"
```

That setting lives in:

- `nvidia-gpu/nvidia-modules-p2p/pkg/production/files/nvidia.conf`

Important: this is a diagnostic/enablement setting, not a validated correctness fix on Talos. With `ForceP2P=17`, Talos can report peer access as available while `simpleP2P` and `p2p_integrity_probe` still fail integrity. The same Arch/NVIDIA stack passes with peer access enabled, so `ForceP2P=17` is not inherently sufficient to explain the corruption.

The build also keeps one additional code path from the donor patch series:

- static BAR1 forced on in the packaged NVIDIA source tree

## Repo Layout

```text
.
├── nvidia-gpu/
│   ├── nvidia-modules-p2p/       # THE custom P2P extension
│   │   ├── source/               #   donor patch metadata and provenance
│   │   ├── kernel/               #   build definitions for module pkg images
│   │   └── pkg/                  #   Talos sysext manifest and package defs
│   ├── nvidia-modules/           # (upstream) stock open-source modules
│   ├── nonfree/                  # (upstream) proprietary driver modules
│   ├── nvidia-container-toolkit/ # (upstream) userspace toolkit + runtime
│   ├── nvidia-fabricmanager/     # (upstream) NVLink fabric manager
│   ├── nvidia-gdrdrv-device/     # (upstream) GPUDirect RDMA device
│   └── vars.yaml                 # shared NVIDIA version variables
├── kernel/                       # local kernel build stages (from siderolabs/pkgs)
│   ├── prepare/                  #   downloads kernel source -> /src
│   ├── build/                    #   applies config, compiles kernel
│   └── kernel/                   #   produces kernel image with same signing key
├── hack/p2p/                     # custom P2P scripts
│   ├── build-installer.sh        #   builds the custom Talos installer image
│   ├── build-samekey-installer-base.py  # rebuilds installer-base with matching key lineage
│   ├── generate-module-signing-key.sh    #   emits a shared module signing key from x509.genkey
│   ├── check-matrix.sh           #   validates release-matrix.yaml consistency
│   ├── check-patch-apply.sh      #   verifies donor patch applies cleanly
│   ├── check-userspace-track.sh  #   validates toolkit track matches driver family
│   └── verify-same-signing-key.sh #  verifies kernel and NVIDIA modules share one signing key
├── docs/
│   └── release-matrix.yaml       # full pinned version matrix
├── PROJECT.yaml                  # custom work metadata
└── (upstream extension dirs...)  # container-runtime/, drivers/, drm/, etc.
```

## Build / Deploy / Verify

### Prerequisites

- Docker with buildx
- `bldr` (Sidero Labs build tool)
- `crane` (for image inspection)
- `talosctl` (Talos CLI)
- A build host with sufficient resources for kernel-heavy compilation (16+ GB RAM recommended)
- Push access to a container registry (e.g., `ghcr.io/<your-org>`)

### 1. Build the P2P kernel module package

Kernel module compilation must happen on a machine with sufficient resources. Sync the repo, then:

```bash
SOURCE_DATE_EPOCH=$(stat -c %Y Pkgfile) \
  make target-nvidia-modules-p2p-production-pkg \
    PLATFORM=linux/amd64 \
    PKGS_PREFIX=ghcr.io/<your-org> \
    PROGRESS=plain \
    TARGET_ARGS='--tag=ghcr.io/<your-org>/nvidia-modules-p2p-production-pkg:<pkgs-version> --push=true'
```

### 2. Build the sysext wrapper

```bash
make target-nvidia-modules-p2p-production \
  PLATFORM=linux/amd64 \
  PKGS_PREFIX=ghcr.io/<your-org> \
  TARGET_ARGS='--tag=ghcr.io/<your-org>/nvidia-modules-p2p-production:<talos-version> --push=true'
```

### 3. Build and publish the custom installer

```bash
bash hack/p2p/build-installer.sh docs/release-matrix.yaml
```

If `docs/release-matrix.yaml` still has null custom artifact pins, pass `CUSTOM_SYSEXT_IMAGE=<ref@digest>` or update the matrix after publishing the sysext.

The script reads version pins from the release matrix, composes the extension set (P2P modules + official toolkit + extras), and publishes the installer image. It enforces overlay ordering so the toolkit's `ld.so.cache` (with NVIDIA library entries) wins over the plain glibc cache.

### 4. Apply to a Talos node

```bash
talosctl upgrade \
  --nodes <node-ip> \
  --image ghcr.io/<your-org>/nvidia-open-gpu-kernel-modules-p2p-installer:<talos-version>@sha256:<installer-digest>
```

### 5. Verify

```bash
# Check node is healthy
talosctl health --nodes <node-ip>

# Check GPU operator status
kubectl get pods -n gpu-operator

# Validate allocatable GPUs
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'

# Verify module/userspace bring-up and live P2P params
talosctl read /proc/version --nodes <node-ip>
talosctl read /proc/driver/nvidia/params --nodes <node-ip>

# Check runtime P2P capability exposure from a GPU pod
nvidia-smi topo -p2p r
nvidia-smi topo -p2p a
p2pBandwidthLatencyTest

# Validate runtime P2P correctness; bandwidth-only samples are not enough
simpleP2P
p2p/p2p_integrity_probe
```

## Contributor Notes

### Critical pitfalls

**Kernel module signing lineage.** Every `.ko` must be signed by the same key that compiled the booted kernel. If you rebuild modules against a different kernel build tree than what ships in the installer, Talos will refuse to load them. The local `kernel/` directory exists specifically to guarantee same-key lineage between the custom NVIDIA modules and the installer's kernel.

**Extension overlay ordering.** The `nvidia-container-toolkit-production` extension ships an `ld.so.cache` that includes NVIDIA library entries. The `glibc` extension ships a plain one. In Talos's overlayfs, the last extension wins. The build script (`hack/p2p/build-installer.sh`) orders toolkit *after* glibc so the NVIDIA-aware cache takes effect. Breaking this order causes `libcuda.so` discovery failures and GPU operator crashes.

**Official vs. custom boundaries.** Only kernel modules are custom. The userspace toolkit, container runtime, fabricmanager, and all other extensions stay on official Talos production artifacts. Don't rebuild what doesn't need the P2P patch.

**Donor patch application.** The aikitoria P2P patch is now kept on its native NVIDIA 595.58.03 base, but the NVIDIA redist archive still has a slightly different directory layout than the GitHub source tree. Paths under `src/` in the donor diff still need remapping to `src/kernel-module-source/src/` before apply. The build recipe handles this automatically.

**Toolkit version pin.** The toolkit version must match the driver family. For the 595.x production track used here, the official toolkit pin is `595.58.03-v1.19.0`. Check `docs/release-matrix.yaml` for the authoritative pin.

### Running validation scripts

```bash
# Validate release matrix consistency
bash hack/p2p/check-matrix.sh docs/release-matrix.yaml

# Verify donor patch still applies cleanly
bash hack/p2p/check-patch-apply.sh docs/release-matrix.yaml

# Check toolkit track matches driver family
bash hack/p2p/check-userspace-track.sh docs/release-matrix.yaml
```

### Where to find deeper context

- Full pinned version matrix: [`docs/release-matrix.yaml`](docs/release-matrix.yaml)
- Engineering findings and contributor gotchas: [`docs/talos-nvidia-p2p-findings.md`](docs/talos-nvidia-p2p-findings.md)
- Per-script documentation: [`hack/p2p/README.md`](hack/p2p/README.md)

## Upstream

This repo tracks [`siderolabs/extensions`](https://github.com/siderolabs/extensions). Custom P2P work is isolated to the directories listed above. Upstream rebases should be straightforward as long as the `nvidia-gpu/nvidia-modules-p2p/`, `kernel/`, `hack/p2p/`, and `docs/` directories aren't touched by upstream.

## License

Same as upstream. See [LICENSE](LICENSE).

# hack/p2p/ ... Custom NVIDIA P2P Workflow Scripts

This directory holds all scripts specific to the P2P (peer-to-peer GPU memory) fork of Talos NVIDIA extensions. Upstream `hack/` files stay at the top level; custom P2P tooling lives here to keep the fork organized without breaking the stock Talos build layout.

## Scripts

### `build-installer.sh`

Builds and publishes a complete custom Talos installer image with the P2P NVIDIA modules baked in.

**What it does:**
1. Reads version pins from `docs/release-matrix.yaml`
2. Pulls the custom P2P sysext image + the official NVIDIA container toolkit
3. Composes the full extension set with correct overlay ordering (toolkit last, after glibc)
4. Runs the Talos imager to produce a custom installer
5. Pushes the result to the container registry

**Usage:**
```bash
bash hack/p2p/build-installer.sh [path-to-release-matrix.yaml]
```

If `artifacts.customSysextImage` is still null during a branch migration, pass `CUSTOM_SYSEXT_IMAGE=<ref@digest>` or update the matrix after publishing the sysext.

**Key environment variables:**
- `EXTRA_SYSTEM_EXTENSION_IMAGES` ... comma-separated list of additional official extensions to include (glibc, binfmt-misc, btrfs, fuse3, qemu-guest-agent, util-linux-tools)
- `BASE_INSTALLER_IMAGE` ... override the base installer image (must have same-key kernel lineage)
- `IMAGER_IMAGE` ... override the Talos imager image
- `CUSTOM_SYSEXT_IMAGE` ... override `artifacts.customSysextImage` with a freshly built digest-pinned sysext ref
- `INSTALLER_SOURCE_LABEL` ... override the OCI source label for the published installer image

**Overlay ordering matters.** The script enforces that `nvidia-container-toolkit-production` is layered *after* `glibc` in the squashfs composition. This is critical because both extensions ship an `ld.so.cache`, and the toolkit's cache includes NVIDIA library entries that CDI generation needs. Talos overlayfs uses extension order to resolve conflicts, so toolkit must win.

### `build-samekey-installer-base.py`

Rebuilds the installer-base image with a kernel that shares the same module-signing key lineage as the locally compiled P2P modules.

The stock `ghcr.io/siderolabs/installer-base:v1.13.0` won't work because its kernel was compiled with a different signing key than the local kernel build tree. This script produces an installer-base whose embedded kernel trusts the same key that signed the custom `.ko` files.

### `check-matrix.sh`

Validates internal consistency of `docs/release-matrix.yaml`. Checks that all required fields are present, types are correct, and cross-references (e.g., toolkit track vs. driver family) are coherent.

```bash
bash hack/p2p/check-matrix.sh docs/release-matrix.yaml
```

### `check-patch-apply.sh`

Verifies that the aikitoria donor P2P patch still applies cleanly to the pinned NVIDIA upstream release. Fetches the diff and the source archive, then runs a dry-run apply.

```bash
bash hack/p2p/check-patch-apply.sh docs/release-matrix.yaml
```

### `check-userspace-track.sh`

Validates that the official NVIDIA container toolkit track matches the selected driver family. Reads `nvidia-gpu/vars.yaml` and the track-specific `vars.yaml` under `nvidia-gpu/nvidia-container-toolkit/` to confirm alignment.

```bash
bash hack/p2p/check-userspace-track.sh docs/release-matrix.yaml
```

### `generate-module-signing-key.sh`

Generates a PEM-encoded module signing key from the kernel build's `x509.genkey` template and prints it as base64. Use this when you need to feed a stable signing key into the same-key kernel/module build flow.

```bash
bash hack/p2p/generate-module-signing-key.sh [path-to-x509.genkey]
```

### `verify-same-signing-key.sh`

Confirms that a kernel image and a P2P module pkg image were signed by the same module-signing key. It extracts `ahci.ko` from the kernel image and `nvidia.ko` from the pkg image, then compares their `modinfo` signer metadata.

```bash
bash hack/p2p/verify-same-signing-key.sh <kernel-image-ref> <p2p-pkg-image-ref>
```

## Relationship to the Build

These scripts are not called by the standard `make` / `bldr` build pipeline. They're separate operational tooling:

- **`make target-nvidia-modules-p2p-production-pkg`** and **`make target-nvidia-modules-p2p-production`** handle the bldr-based module compilation and sysext packaging.
- **`build-installer.sh`** runs *after* the sysext is published, composing it into a deployable installer.
- **`generate-module-signing-key.sh`** and **`verify-same-signing-key.sh`** support the same-key signing workflow used to keep the kernel and NVIDIA modules loadable together.
- **`check-*.sh`** scripts are pre-flight validations you can run at any time.

## Version Pins

All scripts read version information from `docs/release-matrix.yaml`. Don't hardcode versions in scripts. If you need to update a version, update the matrix first, then re-run the validators.

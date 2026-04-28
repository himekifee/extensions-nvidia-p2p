#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [path-to-release-matrix.yaml]" >&2
  echo "Optional env: EXTRA_SYSTEM_EXTENSION_IMAGE=<image-ref>" >&2
  echo "Optional env: EXTRA_SYSTEM_EXTENSION_IMAGES=<image-ref[,image-ref...]>" >&2
  echo "Optional env: EXTRA_KERNEL_ARG=<kernel-arg>" >&2
  echo "Optional env: EXTRA_KERNEL_ARGS=<kernel-arg[,kernel-arg...]>" >&2
  echo "Optional env: IMAGER_IMAGE=<image-ref>" >&2
  echo "Optional env: BASE_INSTALLER_IMAGE=<image-ref>" >&2
  echo "Optional env: SAMEKEY_KERNEL_IMAGE=<image-ref>" >&2
  echo "Optional env: P2P_PKG_IMAGE=<image-ref>" >&2
  echo "Optional env: CUSTOM_SYSEXT_IMAGE=<digest-pinned-image-ref>" >&2
  echo "Optional env: CUSTOM_TOOLKIT_IMAGE=<digest-pinned-image-ref>" >&2
  echo "Optional env: INSTALLER_SOURCE_LABEL=<oci-source-url>" >&2
  echo "Optional env: PUSH_INSTALLER=true|false (default true)" >&2
  exit 1
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command '$1' is not installed"
  fi
}

push_with_retry() {
  local image_ref="$1"
  local attempts="${2:-5}"
  local delay_seconds="${3:-5}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if docker push "$image_ref"; then
      return 0
    fi

    if [ "$attempt" -eq "$attempts" ]; then
      fail "failed to push '$image_ref' after ${attempts} attempts"
    fi

    printf 'docker push failed for %s (attempt %s/%s); retrying in %ss\n' \
      "$image_ref" "$attempt" "$attempts" "$delay_seconds" >&2
    sleep "$delay_seconds"
  done
}

ensure_image_available() {
  local image_ref="$1"

  if docker image inspect "$image_ref" >/dev/null 2>&1; then
    return 0
  fi

  docker pull "$image_ref" >/dev/null
}

extract_initrd_rootfs() {
  local initrd_path="$1"
  local output_path="$2"

  python3 - "$initrd_path" "$output_path" <<'PY'
import lzma
import subprocess
import sys
from pathlib import Path


def align(value: int) -> int:
    return (value + 3) & ~3


initrd_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
data = initrd_path.read_bytes()

if data.startswith(b"\x28\xb5\x2f\xfd"):
    data = subprocess.run(
        ["zstd", "-q", "-d", "-c", str(initrd_path)],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
elif data.startswith(b"\xfd7zXZ\x00"):
    data = lzma.decompress(data)

offset = 0
while offset + 110 <= len(data):
    if data[offset:offset + 6] != b"070701":
        raise SystemExit(f"bad cpio magic at offset {offset}")

    fields = [
        int(data[offset + 6 + index:offset + 14 + index], 16)
        for index in range(0, 13 * 8, 8)
    ]
    header_end = offset + 110
    namesize = fields[11]
    filesize = fields[6]
    name = data[header_end:header_end + namesize - 1].decode("utf-8")
    offset = align(header_end + namesize)
    filedata = data[offset:offset + filesize]
    offset = align(offset + filesize)

    if name == "TRAILER!!!":
        raise SystemExit("rootfs.sqsh not found in UKI initrd")

    if name == "rootfs.sqsh":
        output_path.write_bytes(filedata)
        break
else:
    raise SystemExit("TRAILER!!! not found in UKI initrd")
PY
}

replace_initrd_rootfs() {
  local current_raw_path="$1"
  local replacement_rootfs_path="$2"
  local output_raw_path="$3"

  python3 - "$current_raw_path" "$replacement_rootfs_path" "$output_raw_path" <<'PY'
import sys
from pathlib import Path


def align(value: int) -> int:
    return (value + 3) & ~3


def parse_first_archive(data: bytes):
    offset = 0
    entries = []

    while offset + 110 <= len(data):
        if data[offset:offset + 6] != b"070701":
            raise SystemExit(f"bad cpio magic at offset {offset}")

        fields = [
            int(data[offset + 6 + index:offset + 14 + index], 16)
            for index in range(0, 13 * 8, 8)
        ]
        header_end = offset + 110
        namesize = fields[11]
        filesize = fields[6]
        name = data[header_end:header_end + namesize - 1].decode("utf-8")
        offset = align(header_end + namesize)
        filedata = data[offset:offset + filesize]
        offset = align(offset + filesize)

        entries.append((name, fields, filedata))

        if name == "TRAILER!!!":
            return entries, data[offset:]

    raise SystemExit("TRAILER!!! not found in initrd archive")


def write_archive(entries) -> bytes:
    output = bytearray()
    for name, fields, filedata in entries:
        encoded_name = name.encode("utf-8") + b"\x00"
        namesize = len(encoded_name)
        fields = list(fields)
        fields[6] = len(filedata)
        fields[11] = namesize
        header = "070701" + "".join(f"{field:08x}" for field in fields)
        output.extend(header.encode("ascii"))
        output.extend(encoded_name)
        output.extend(b"\x00" * ((4 - ((110 + namesize) % 4)) % 4))
        output.extend(filedata)
        output.extend(b"\x00" * ((4 - (len(filedata) % 4)) % 4))
    return bytes(output)


current_raw_path = Path(sys.argv[1])
replacement_rootfs_path = Path(sys.argv[2])
output_raw_path = Path(sys.argv[3])

current_raw = current_raw_path.read_bytes()
replacement_rootfs = replacement_rootfs_path.read_bytes()
entries, trailing_data = parse_first_archive(current_raw)
replaced = False

rebuilt_entries = []
for name, fields, filedata in entries:
    if name == "rootfs.sqsh":
        filedata = replacement_rootfs
        replaced = True
    rebuilt_entries.append((name, fields, filedata))

if not replaced:
    raise SystemExit("rootfs.sqsh not found in initrd archive")

output_raw_path.write_bytes(write_archive(rebuilt_entries) + trailing_data)
PY
}

replace_rootfs_modules_with_kernel_modules() {
  local rootfs_path="$1"
  local kernel_image_ref="$2"
  local working_dir="$3"
  local output_path="$4"
  local rootfs_dir="$working_dir/rootfs"
  local samekey_modules_dir="$working_dir/samekey-modules"

  rm -rf "$rootfs_dir" "$samekey_modules_dir" "$output_path"
  mkdir -p "$working_dir"

  unsquashfs -no-xattrs -f -d "$rootfs_dir" "$rootfs_path" >/dev/null
  chmod -R u+rwX "$rootfs_dir"

  base_container_id="$(docker create "$kernel_image_ref" sh)"
  docker cp "$base_container_id:/usr/lib/modules" "$samekey_modules_dir"
  docker rm "$base_container_id" >/dev/null
  base_container_id=""

  if [ ! -d "$samekey_modules_dir" ]; then
    fail "could not extract same-key modules from '$kernel_image_ref'"
  fi

  rm -rf "$rootfs_dir/usr/lib/modules"
  mkdir -p "$rootfs_dir/usr/lib"
  cp -a "$samekey_modules_dir" "$rootfs_dir/usr/lib/modules"

  mksquashfs "$rootfs_dir" "$output_path" \
    -all-root \
    -comp zstd \
    -Xcompression-level 18 \
    -b 131072 \
    -noappend \
    -quiet \
    >/dev/null
}

verify_rootfs_default_link() {
  local rootfs_path="$1"

  if ! unsquashfs -cat "$rootfs_path" usr/lib/systemd/network/99-default.link >/dev/null 2>&1; then
    fail "final UKI rootfs.sqsh is missing usr/lib/systemd/network/99-default.link"
  fi

  printf 'verified final UKI rootfs contains usr/lib/systemd/network/99-default.link\n'
}

extract_ahci_from_rootfs() {
  local rootfs_path="$1"
  local output_dir="$2"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  unsquashfs -no-xattrs -f -d "$output_dir" "$rootfs_path" usr/lib/modules >/dev/null
  extracted_ahci_path="$(find "$output_dir" -name 'ahci.ko' -print -quit)"

  if [ -z "$extracted_ahci_path" ]; then
    fail "could not find ahci.ko in final UKI rootfs.sqsh"
  fi
}

extract_nvidia_from_p2p_pkg() {
  local output_dir="$1"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  ensure_image_available "$p2p_pkg_ref"
  pkg_container_id="$(docker create "$p2p_pkg_ref" sh)"
  docker cp "$pkg_container_id:/usr/lib/modules" "$output_dir/modules"
  docker rm "$pkg_container_id" >/dev/null
  pkg_container_id=""
  extracted_nvidia_path="$(find "$output_dir/modules" -name 'nvidia.ko' -print -quit)"

  if [ -z "$extracted_nvidia_path" ]; then
    fail "could not find nvidia.ko in '$p2p_pkg_ref'"
  fi
}

verify_p2p_pkg_signing_key() {
  local rootfs_path="$1"
  local working_dir="$2"
  local ahci_signer
  local ahci_sig_key
  local nvidia_signer
  local nvidia_sig_key

  extracted_ahci_path=""
  extracted_nvidia_path=""
  extract_ahci_from_rootfs "$rootfs_path" "$working_dir/rootfs-modules"
  extract_nvidia_from_p2p_pkg "$working_dir/p2p-pkg-modules"

  ahci_signer="$(modinfo -F signer "$extracted_ahci_path")"
  ahci_sig_key="$(modinfo -F sig_key "$extracted_ahci_path")"
  nvidia_signer="$(modinfo -F signer "$extracted_nvidia_path")"
  nvidia_sig_key="$(modinfo -F sig_key "$extracted_nvidia_path")"

  printf 'final rootfs ahci signer: %s\n' "$ahci_signer"
  printf 'final rootfs ahci sig_key: %s\n' "$ahci_sig_key"
  printf 'p2p pkg nvidia signer: %s\n' "$nvidia_signer"
  printf 'p2p pkg nvidia sig_key: %s\n' "$nvidia_sig_key"

  if [ -z "$ahci_sig_key" ] || [ -z "$nvidia_sig_key" ]; then
    fail "missing module signing key metadata in final rootfs or P2P pkg"
  fi

  if [ "$ahci_sig_key" != "$nvidia_sig_key" ]; then
    fail "final rootfs ahci.ko and P2P pkg nvidia.ko were signed by different keys"
  fi

  printf 'verified final rootfs and P2P pkg shared signing key: %s\n' "$ahci_sig_key"
}

verify_final_installer_image() {
  local image_ref="$1"
  local selected_vmlinuz_path="$2"
  local check_dir="$3"

  rm -rf "$check_dir"
  mkdir -p "$check_dir"

  container_id="$(docker create "$image_ref")"
  docker cp "$container_id:/usr/install/${arch}/vmlinuz" "$check_dir/vmlinuz"
  docker cp "$container_id:/usr/install/${arch}/initramfs.xz" "$check_dir/initramfs.xz"
  docker cp "$container_id:/usr/install/${arch}/vmlinuz.efi" "$check_dir/vmlinuz.efi"
  docker rm "$container_id" >/dev/null
  container_id=""

  chmod 644 "$check_dir/vmlinuz.efi"
  objcopy --dump-section .linux="$check_dir/uki-linux" "$check_dir/vmlinuz.efi"
  objcopy --dump-section .initrd="$check_dir/uki-initrd.bin" "$check_dir/vmlinuz.efi"

  if ! cmp -s "$check_dir/vmlinuz" "$check_dir/uki-linux"; then
    fail "final installer vmlinuz differs from final UKI .linux in '$image_ref'"
  fi

  if ! cmp -s "$check_dir/uki-linux" "$selected_vmlinuz_path"; then
    fail "final UKI .linux differs from the selected same-key kernel in '$image_ref'"
  fi

  printf 'verified final installer vmlinuz matches UKI .linux\n'
  printf 'verified final UKI .linux matches selected same-key kernel\n'

  extract_initrd_rootfs "$check_dir/uki-initrd.bin" "$check_dir/rootfs.sqsh"
  extract_initrd_rootfs "$check_dir/initramfs.xz" "$check_dir/initramfs-rootfs.sqsh"
  if ! cmp -s "$check_dir/rootfs.sqsh" "$check_dir/initramfs-rootfs.sqsh"; then
    fail "final installer initramfs.xz rootfs differs from final UKI .initrd rootfs"
  fi

  printf 'verified final installer initramfs.xz rootfs matches UKI .initrd rootfs\n'
  verify_rootfs_default_link "$check_dir/rootfs.sqsh"

  if [ -n "$p2p_pkg_ref" ]; then
    verify_p2p_pkg_signing_key "$check_dir/rootfs.sqsh" "$check_dir"
  fi

  printf 'verified final installer image lineage: %s\n' "$image_ref"
}

if [ "$#" -gt 1 ]; then
  usage
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$(dirname "$script_dir")")"
matrix_path="${1:-$repo_root/docs/release-matrix.yaml}"

if [ ! -f "$matrix_path" ]; then
  fail "release matrix not found at '$matrix_path'"
fi

for cmd in docker python3 objcopy objdump zstd xz grep mktemp unsquashfs mksquashfs cmp find cp chmod; do
  require_command "$cmd"
done

docker_config_dir="${DOCKER_CONFIG:-$HOME/.docker}"
docker_config_path="$docker_config_dir/config.json"

if [ ! -f "$docker_config_path" ]; then
  fail "Docker registry auth config not found at '$docker_config_path'"
fi

mapfile -t matrix_values < <(python3 - "$matrix_path" <<'PY'
import os
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError as exc:
    print(f"error: {exc}. Install PyYAML to build the custom installer image.", file=sys.stderr)
    sys.exit(1)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def require_string(document, path):
    current = document
    for key in path:
        if not isinstance(current, dict) or key not in current:
            fail(f"missing required field: {'.'.join(path)}")
        current = current[key]
    if not isinstance(current, str) or not current.strip():
        fail(f"field must be a non-empty string: {'.'.join(path)}")
    return current.strip()


matrix_path = Path(sys.argv[1])
with matrix_path.open("r", encoding="utf-8") as stream:
    document = yaml.safe_load(stream)

target_talos_version = require_string(document, ["targetTalosVersion"])
arch = require_string(document, ["arch"])
origin_repo = require_string(document, ["repository", "origin"])
custom_sysext_image_override = os.environ.get("CUSTOM_SYSEXT_IMAGE", "").strip()
custom_toolkit_image_override = os.environ.get("CUSTOM_TOOLKIT_IMAGE", "").strip()

if custom_sysext_image_override:
    custom_sysext_image = custom_sysext_image_override
else:
    custom_sysext_image = require_string(document, ["artifacts", "customSysextImage"])
    custom_sysext_digest = require_string(document, ["artifacts", "customSysextDigest"])
official_open_module_ref = require_string(document, ["nvidia", "officialOpenModuleExtension", "ref"])
official_open_module_digest = require_string(document, ["nvidia", "officialOpenModuleExtension", "digest"])
toolkit_ref = require_string(document, ["nvidia", "officialUserspaceToolkitExtension", "ref"])
toolkit_digest = require_string(document, ["nvidia", "officialUserspaceToolkitExtension", "digest"])

if "@" not in custom_sysext_image:
    fail("custom sysext image must be digest-pinned")

if not custom_sysext_image_override:
    custom_sysext_image_digest = custom_sysext_image.rsplit("@", 1)[1]
    if custom_sysext_image_digest != custom_sysext_digest:
        fail(
            "artifacts.customSysextImage digest "
            f"'{custom_sysext_image_digest}' does not match artifacts.customSysextDigest '{custom_sysext_digest}'"
        )

if custom_toolkit_image_override:
    toolkit_image = custom_toolkit_image_override
    if "@" not in toolkit_image:
        fail("custom toolkit image must be digest-pinned")
elif "@" in toolkit_ref:
    toolkit_ref_digest = toolkit_ref.rsplit("@", 1)[1]
    if toolkit_ref_digest != toolkit_digest:
        fail(
            "nvidia.officialUserspaceToolkitExtension.ref digest "
            f"'{toolkit_ref_digest}' does not match nvidia.officialUserspaceToolkitExtension.digest '{toolkit_digest}'"
        )
    toolkit_image = toolkit_ref
else:
    toolkit_image = f"{toolkit_ref}@{toolkit_digest}"

if "@" in official_open_module_ref:
    official_open_module_ref_digest = official_open_module_ref.rsplit("@", 1)[1]
    if official_open_module_ref_digest != official_open_module_digest:
        fail(
            "nvidia.officialOpenModuleExtension.ref digest "
            f"'{official_open_module_ref_digest}' does not match nvidia.officialOpenModuleExtension.digest '{official_open_module_digest}'"
        )
    official_open_module_image = official_open_module_ref
else:
    official_open_module_image = f"{official_open_module_ref}@{official_open_module_digest}"

print(target_talos_version)
print(arch)
print(custom_sysext_image)
print(toolkit_image)
print(official_open_module_image)
print(origin_repo)
print(f"ghcr.io/{origin_repo}/nvidia-open-gpu-kernel-modules-p2p-installer")
PY
)

if [ "${#matrix_values[@]}" -ne 7 ]; then
  fail "failed to read installer inputs from '$matrix_path'"
fi

target_talos_version="${matrix_values[0]}"
arch="${matrix_values[1]}"
custom_sysext_ref="${matrix_values[2]}"
toolkit_ref="${matrix_values[3]}"
official_open_module_ref="${matrix_values[4]}"
origin_repo="${matrix_values[5]}"
installer_image_repo="${INSTALLER_IMAGE_REPO:-${matrix_values[6]}}"
installer_image_tag="${INSTALLER_IMAGE_TAG:-$target_talos_version}"
installer_image_ref="${installer_image_repo}:${installer_image_tag}"
installer_pull_ref="${installer_image_repo}"
installer_source_label="${INSTALLER_SOURCE_LABEL:-https://github.com/${origin_repo}}"
imager_image="${IMAGER_IMAGE:-ghcr.io/siderolabs/imager:${target_talos_version}}"
base_installer_ref="${BASE_INSTALLER_IMAGE:-ghcr.io/siderolabs/installer-base:${target_talos_version}}"
samekey_kernel_ref="${SAMEKEY_KERNEL_IMAGE:-}"
p2p_pkg_ref="${P2P_PKG_IMAGE:-}"
push_installer=true
case "${PUSH_INSTALLER:-true}" in
  0|false|no|False|No) push_installer=false ;;
esac
extra_system_extension_ref="${EXTRA_SYSTEM_EXTENSION_IMAGE:-}"
extra_system_extension_refs=()
extra_kernel_arg="${EXTRA_KERNEL_ARG:-}"
extra_kernel_args=()

if [ -n "$p2p_pkg_ref" ]; then
  require_command modinfo
fi

if [ "${GITHUB_ACTIONS:-}" = true ] && [[ "$imager_image" != *@sha256:* ]]; then
  fail "IMAGER_IMAGE must be digest-pinned in GitHub Actions"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/talos-installer-build-XXXXXX")"
container_id=""
base_container_id=""
pkg_container_id=""

cleanup() {
  if [ -n "$container_id" ]; then
    docker rm "$container_id" >/dev/null 2>&1 || true
  fi
  if [ -n "$base_container_id" ]; then
    docker rm "$base_container_id" >/dev/null 2>&1 || true
  fi
  if [ -n "$pkg_container_id" ]; then
    docker rm "$pkg_container_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}

trap cleanup EXIT

out_dir="$tmp_dir/out"
verify_dir="$tmp_dir/verify"
relabel_dir="$tmp_dir/relabel"
log_path="$tmp_dir/imager.log"

mkdir -p "$out_dir"
mkdir -p "$verify_dir"
mkdir -p "$relabel_dir"

ordered_system_extension_refs=(
  "$custom_sysext_ref"
)
system_extension_args=()

if [ -n "${EXTRA_SYSTEM_EXTENSION_IMAGES:-}" ]; then
  while IFS= read -r ref || [ -n "$ref" ]; do
    if [ -n "$ref" ]; then
      extra_system_extension_refs+=("$ref")
    fi
  done < <(printf '%s' "$EXTRA_SYSTEM_EXTENSION_IMAGES" | tr ',' '\n')
fi

if [ -n "$extra_system_extension_ref" ]; then
  extra_system_extension_refs+=("$extra_system_extension_ref")
fi

for extra_system_extension_ref in "${extra_system_extension_refs[@]}"; do
  case "$extra_system_extension_ref" in
    "$custom_sysext_ref"|"$toolkit_ref")
      continue
      ;;
    "$official_open_module_ref"|*nvidia-open-gpu-kernel-modules-production*)
      fail "duplicate-driver-source: refusing to build with both '$custom_sysext_ref' and '$official_open_module_ref'"
      ;;
  esac

  ordered_system_extension_refs+=("$extra_system_extension_ref")
done

ordered_system_extension_refs+=("$toolkit_ref")

for system_extension_ref in "${ordered_system_extension_refs[@]}"; do
  system_extension_args+=(--system-extension-image "$system_extension_ref")
done

printf 'installer system extension order:\n'
printf ' - %s\n' "${ordered_system_extension_refs[@]}"

if [ -n "${EXTRA_KERNEL_ARGS:-}" ]; then
  while IFS= read -r arg || [ -n "$arg" ]; do
    if [ -n "$arg" ]; then
      extra_kernel_args+=("$arg")
    fi
  done < <(printf '%s' "$EXTRA_KERNEL_ARGS" | tr ',' '\n')
fi

if [ -n "$extra_kernel_arg" ]; then
  extra_kernel_args+=("$extra_kernel_arg")
fi

kernel_arg_args=()

for extra_kernel_arg in "${extra_kernel_args[@]}"; do
  kernel_arg_args+=(--extra-kernel-arg "$extra_kernel_arg")
done

printf 'building custom installer with %s\n' "$imager_image"

docker run --rm -e DOCKER_CONFIG=/root/.docker -v "$docker_config_dir:/root/.docker:ro" -v "$out_dir:/out" "$imager_image" installer --platform=metal --arch="$arch" --base-installer-image "$base_installer_ref" "${system_extension_args[@]}" "${kernel_arg_args[@]}" 2>&1 | tee "$log_path"

installer_tar="$out_dir/installer-${arch}.tar"

if [ ! -f "$installer_tar" ]; then
  fail "installer tarball not found at '$installer_tar'"
fi

printf 'loading installer tarball %s\n' "$installer_tar"
load_output="$(docker load -i "$installer_tar")"

loaded_image_ref=""
loaded_image_id=""

while IFS= read -r line; do
  case "$line" in
    'Loaded image:'*)
      loaded_image_ref="${line#Loaded image: }"
      ;;
    'Loaded image ID:'*)
      loaded_image_id="${line#Loaded image ID: }"
      ;;
  esac
done <<< "$load_output"

if [ -z "$loaded_image_ref" ] && [ -z "$loaded_image_id" ]; then
  loaded_image_ref="$base_installer_ref"
fi

if [ -z "$loaded_image_id" ]; then
  loaded_image_id="$(docker image inspect "$loaded_image_ref" --format '{{.Id}}')"
fi

container_id="$(docker create "$loaded_image_id")"
docker cp "$container_id:/usr/install/${arch}/vmlinuz" "$verify_dir/imager-vmlinuz"
docker cp "$container_id:/usr/install/${arch}/vmlinuz.efi" "$relabel_dir/vmlinuz.efi"
docker rm "$container_id" >/dev/null
container_id=""

if [ -n "$samekey_kernel_ref" ]; then
  base_container_id="$(docker create "$samekey_kernel_ref" sh)"
  docker cp "$base_container_id:/boot/vmlinuz" "$verify_dir/vmlinuz"
else
  base_container_id="$(docker create "$base_installer_ref" sh)"
  docker cp "$base_container_id:/usr/install/${arch}/vmlinuz" "$verify_dir/vmlinuz"
fi
docker rm "$base_container_id" >/dev/null
base_container_id=""

if cmp -s "$verify_dir/imager-vmlinuz" "$verify_dir/vmlinuz"; then
  printf 'installer kernel matches base installer kernel\n'
else
  printf 'imager output kernel differs from base installer kernel; using base installer kernel for final installer\n'
fi

chmod 644 "$relabel_dir/vmlinuz.efi"

linux_vma="$(python3 - "$relabel_dir/vmlinuz.efi" .linux <<'PY'
import subprocess
import sys

binary_path = sys.argv[1]
section_name = sys.argv[2]
objdump_output = subprocess.check_output(["objdump", "-h", binary_path], text=True)

for line in objdump_output.splitlines():
    parts = line.split()
    if len(parts) >= 4 and parts[1] == section_name:
        print(f"0x{parts[3]}")
        break
else:
    raise SystemExit(f"section {section_name} not found in {binary_path}")
PY
)"

initrd_vma="$(python3 - "$relabel_dir/vmlinuz.efi" .initrd <<'PY'
import subprocess
import sys

binary_path = sys.argv[1]
section_name = sys.argv[2]
objdump_output = subprocess.check_output(["objdump", "-h", binary_path], text=True)

for line in objdump_output.splitlines():
    parts = line.split()
    if len(parts) >= 4 and parts[1] == section_name:
        print(f"0x{parts[3]}")
        break
else:
    raise SystemExit(f"section {section_name} not found in {binary_path}")
PY
)"

cmdline_vma="$(python3 - "$relabel_dir/vmlinuz.efi" .cmdline <<'PY'
import subprocess
import sys

binary_path = sys.argv[1]
section_name = sys.argv[2]
objdump_output = subprocess.check_output(["objdump", "-h", binary_path], text=True)

for line in objdump_output.splitlines():
    parts = line.split()
    if len(parts) >= 4 and parts[1] == section_name:
        print(f"0x{parts[3]}")
        break
else:
    raise SystemExit(f"section {section_name} not found in {binary_path}")
PY
)"

objcopy --dump-section .cmdline="$verify_dir/cmdline.bin" "$relabel_dir/vmlinuz.efi"

objcopy --dump-section .initrd="$verify_dir/current-initrd.zst" "$relabel_dir/vmlinuz.efi"
zstd -q -d -f "$verify_dir/current-initrd.zst" -o "$verify_dir/current-initrd.raw"

printf 'extracting installer extension archive for overlay verification\n'
python3 - "$verify_dir/current-initrd.raw" "$verify_dir" <<'PY'
from pathlib import Path
import sys


def align(value: int) -> int:
    return (value + 3) & ~3


def parse_archive(data: bytes, offset: int):
    entries = []

    while offset + 110 <= len(data):
        if data[offset:offset + 6] != b"070701":
            raise SystemExit(f"bad cpio magic at offset {offset}")

        fields = [
            int(data[offset + 6 + index:offset + 14 + index], 16)
            for index in range(0, 13 * 8, 8)
        ]
        header_end = offset + 110
        namesize = fields[11]
        name = data[header_end:header_end + namesize - 1].decode("utf-8")
        offset = align(header_end + namesize)
        filesize = fields[6]
        filedata = data[offset:offset + filesize]
        offset = align(offset + filesize)

        if name == "TRAILER!!!":
            return entries, offset

        entries.append((name, filedata))

    raise SystemExit("TRAILER!!! not found in initrd archive")


raw_path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
data = raw_path.read_bytes()

_, next_offset = parse_archive(data, 0)
second_archive_offset = data.find(b"070701", next_offset)
if second_archive_offset < 0:
    raise SystemExit("system extensions archive not found in initrd")

entries, _ = parse_archive(data, second_archive_offset)
for name, filedata in entries:
    if "/" in name:
        continue
    if not (name.endswith(".sqsh") or name == "extensions.yaml"):
        continue
    (output_dir / name).write_bytes(filedata)
PY

mapfile -t overlay_verification < <(python3 - "$verify_dir/extensions.yaml" <<'PY'
import sys

try:
    import yaml
except ModuleNotFoundError as exc:
    print(f"error: {exc}. Install PyYAML to verify installer overlay order.", file=sys.stderr)
    raise SystemExit(1)

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    document = yaml.safe_load(stream)

layers = document.get("layers") or []
ordered_names = [layer["metadata"]["name"] for layer in layers]
toolkit_name = "nvidia-container-toolkit-production"
glibc_name = "glibc"

if toolkit_name not in ordered_names:
    raise SystemExit(f"{toolkit_name} missing from installer extension archive")

if glibc_name not in ordered_names:
    raise SystemExit(f"{glibc_name} missing from installer extension archive")

toolkit_index = ordered_names.index(toolkit_name)
glibc_index = ordered_names.index(glibc_name)
if toolkit_index <= glibc_index:
    raise SystemExit(
        f"overlay order invalid: {toolkit_name} index {toolkit_index} must be after {glibc_name} index {glibc_index}"
    )

toolkit_layer = layers[toolkit_index]["image"]
print(toolkit_layer)
for name in ordered_names:
    print(name)
PY
)

if [ "${#overlay_verification[@]}" -lt 2 ]; then
  fail "failed to read installer extension overlay order"
fi

toolkit_layer_sqsh="${overlay_verification[0]}"
overlay_order_names=("${overlay_verification[@]:1}")

printf 'verified installer overlay order:\n'
printf ' - %s\n' "${overlay_order_names[@]}"

extract_initrd_rootfs "$verify_dir/current-initrd.zst" "$verify_dir/current-rootfs.sqsh"

if [ -n "$samekey_kernel_ref" ]; then
  printf 'replacing imager rootfs modules with same-key kernel modules\n'
  replace_rootfs_modules_with_kernel_modules \
    "$verify_dir/current-rootfs.sqsh" \
    "$samekey_kernel_ref" \
    "$verify_dir/rootfs-rebuild" \
    "$verify_dir/rebuilt-rootfs.sqsh"
else
  cp "$verify_dir/current-rootfs.sqsh" "$verify_dir/rebuilt-rootfs.sqsh"
fi

replace_initrd_rootfs \
  "$verify_dir/current-initrd.raw" \
  "$verify_dir/rebuilt-rootfs.sqsh" \
  "$verify_dir/rebuilt-initrd.raw"
zstd -q -19 -f "$verify_dir/rebuilt-initrd.raw" -o "$verify_dir/current-initrd.zst"
xz -q -9 -c "$verify_dir/rebuilt-initrd.raw" >"$verify_dir/initramfs.xz"

objcopy --remove-section .profile --remove-section .cmdline --remove-section .linux --remove-section .initrd "$relabel_dir/vmlinuz.efi" "$relabel_dir/vmlinuz-stripped.efi"
objcopy \
  --add-section .cmdline="$verify_dir/cmdline.bin" \
  --change-section-vma .cmdline="$cmdline_vma" \
  --set-section-flags .cmdline=contents,alloc,load,readonly,data \
  --add-section .linux="$verify_dir/vmlinuz" \
  --change-section-vma .linux="$linux_vma" \
  --set-section-flags .linux=contents,alloc,load,readonly,data \
  --add-section .initrd="$verify_dir/current-initrd.zst" \
  --change-section-vma .initrd="$initrd_vma" \
  --set-section-flags .initrd=contents,alloc,load,readonly,data \
  "$relabel_dir/vmlinuz-stripped.efi" \
  "$relabel_dir/vmlinuz.efi"

relabel_base_ref="local-installer-relabel:${target_talos_version}"

cp "$verify_dir/vmlinuz" "$relabel_dir/vmlinuz"
cp "$verify_dir/initramfs.xz" "$relabel_dir/initramfs.xz"
chmod 644 "$relabel_dir/vmlinuz"
chmod 644 "$relabel_dir/initramfs.xz"

printf 'tagging installer base image as %s\n' "$relabel_base_ref"
docker tag "$loaded_image_id" "$relabel_base_ref"

cat >"$relabel_dir/Dockerfile" <<EOF
FROM ${relabel_base_ref}
COPY vmlinuz /usr/install/${arch}/vmlinuz
COPY initramfs.xz /usr/install/${arch}/initramfs.xz
COPY vmlinuz.efi /usr/install/${arch}/vmlinuz.efi
LABEL org.opencontainers.image.source=${installer_source_label}
EOF

printf 'relabeling installer image as %s\n' "$installer_image_ref"
docker build --pull=false --tag "$installer_image_ref" "$relabel_dir" >/dev/null

verify_final_installer_image "$installer_image_ref" "$verify_dir/vmlinuz" "$verify_dir/final-local"

if [ "$push_installer" = false ]; then
  printf 'installer image built locally: %s\n' "$installer_image_ref"
  printf 'push deferred (PUSH_INSTALLER=false)\n'
  exit 0
fi

printf 'pushing installer image %s\n' "$installer_image_ref"
push_with_retry "$installer_image_ref"

inspect_output="$(docker buildx imagetools inspect "$installer_image_ref")"
installer_digest=""

while IFS= read -r line; do
  case "$line" in
    Digest:*)
      installer_digest="${line#Digest:}"
      installer_digest="${installer_digest#${installer_digest%%[![:space:]]*}}"
      ;;
  esac
done <<< "$inspect_output"

if [ -z "$installer_digest" ]; then
  fail "unable to determine the pushed digest for '$installer_image_ref'"
fi

installer_digest_ref="${installer_image_ref}@${installer_digest}"

printf 'pulling installer image by digest %s\n' "$installer_digest_ref"
docker pull "${installer_pull_ref}@${installer_digest}" >/dev/null

verify_final_installer_image "$installer_digest_ref" "$verify_dir/vmlinuz" "$verify_dir/final-pushed"

extension_names="$(python3 - "$verify_dir/final-pushed/uki-initrd.bin" <<'PY'
import lzma
import re
import subprocess
import sys
from pathlib import Path

initrd_path = Path(sys.argv[1])
data = initrd_path.read_bytes()

if data.startswith(b"\x28\xb5\x2f\xfd"):
    raw = subprocess.run(
        ["zstd", "-q", "-d", "-c", str(initrd_path)],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
elif data.startswith(b"\xfd7zXZ\x00"):
    raw = lzma.decompress(data)
else:
    raw = data

text = raw.decode("utf-8", errors="ignore")
pattern = re.compile(
    r"name: (nvidia-modules-p2p-production|nvidia-container-toolkit-production|nvidia-open-gpu-kernel-modules-production)"
)

for match in pattern.finditer(text):
    print(match.group(0))
PY
)"

if ! printf '%s\n' "$extension_names" | grep -F "name: nvidia-modules-p2p-production" >/dev/null; then
  fail "custom P2P NVIDIA sysext is missing from the installer initrd"
fi
printf '%s\n' "$extension_names" | grep -F "name: nvidia-container-toolkit-production" >/dev/null || fail "NVIDIA userspace toolkit sysext is missing from the installer initrd"

if printf '%s\n' "$extension_names" | grep -F "name: nvidia-open-gpu-kernel-modules-production" >/dev/null; then
  fail "official nvidia-open-gpu-kernel-modules-production was included alongside the custom P2P sysext"
fi

printf 'verified installer image: %s\n' "$installer_digest_ref"
printf 'verified installer digest: %s\n' "$installer_digest"
printf 'verified included extensions:\n%s\n' "$extension_names"
printf 'verified excluded extension: nvidia-open-gpu-kernel-modules-production\n'
printf 'upgrade image matches installer image: %s\n' "$installer_digest_ref"

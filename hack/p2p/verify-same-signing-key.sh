#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <kernel-image-ref> <p2p-pkg-image-ref>" >&2
  exit 1
fi

for cmd in docker find mktemp modinfo; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' is not installed" >&2
    exit 1
  fi
done

kernel_image="$1"
p2p_pkg_image="$2"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/verify-same-signing-key-XXXXXX")"
kernel_container_id=""
pkg_container_id=""

cleanup() {
  if [ -n "$kernel_container_id" ]; then
    docker rm "$kernel_container_id" >/dev/null 2>&1 || true
  fi

  if [ -n "$pkg_container_id" ]; then
    docker rm "$pkg_container_id" >/dev/null 2>&1 || true
  fi

  rm -rf "$tmp_dir"
}

trap cleanup EXIT

kernel_container_id="$(docker create "$kernel_image" sh)"
pkg_container_id="$(docker create "$p2p_pkg_image" sh)"

docker cp "$kernel_container_id:/usr/lib/modules" "$tmp_dir/kernelmods"
docker cp "$pkg_container_id:/usr/lib/modules" "$tmp_dir/pkgmods"

ahci_path="$(find "$tmp_dir/kernelmods" -name 'ahci.ko' | head -n1)"
nvidia_path="$(find "$tmp_dir/pkgmods" -name 'nvidia.ko' | head -n1)"

if [ -z "$ahci_path" ]; then
  echo "error: could not find ahci.ko in '$kernel_image'" >&2
  exit 1
fi

if [ -z "$nvidia_path" ]; then
  echo "error: could not find nvidia.ko in '$p2p_pkg_image'" >&2
  exit 1
fi

kernel_signer="$(modinfo -F signer "$ahci_path")"
kernel_sig_key="$(modinfo -F sig_key "$ahci_path")"
nvidia_signer="$(modinfo -F signer "$nvidia_path")"
nvidia_sig_key="$(modinfo -F sig_key "$nvidia_path")"

printf 'kernel signer: %s\n' "$kernel_signer"
printf 'kernel sig_key: %s\n' "$kernel_sig_key"
printf 'nvidia signer: %s\n' "$nvidia_signer"
printf 'nvidia sig_key: %s\n' "$nvidia_sig_key"

if [ "$kernel_sig_key" != "$nvidia_sig_key" ]; then
  echo "error: kernel and NVIDIA modules were signed by different keys" >&2
  exit 1
fi

printf 'verified shared signing key: %s\n' "$kernel_sig_key"

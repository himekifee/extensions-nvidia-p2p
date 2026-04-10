#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$(dirname "$script_dir")")"
config_path="${1:-$repo_root/kernel/build/certs/x509.genkey}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl is required to generate a shared module signing key" >&2
  exit 1
fi

if ! command -v base64 >/dev/null 2>&1; then
  echo "error: base64 is required to encode the shared module signing key" >&2
  exit 1
fi

if [ ! -f "$config_path" ]; then
  echo "error: kernel signing config not found at '$config_path'" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/module-signing-key-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

key_path="$tmp_dir/signing_key.pem"

openssl req \
  -new \
  -newkey rsa:4096 \
  -nodes \
  -utf8 \
  -sha512 \
  -days 36500 \
  -batch \
  -x509 \
  -config "$config_path" \
  -keyout "$key_path" \
  -out "$key_path" \
  >/dev/null 2>&1

base64 -w0 "$key_path"

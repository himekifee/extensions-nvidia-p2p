#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <path-to-release-matrix.yaml>" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  usage
fi

matrix_path="$1"

if [ ! -f "$matrix_path" ]; then
  echo "error: release matrix not found at '$matrix_path'" >&2
  exit 1
fi

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

matrix_output="$(python3 - "$matrix_path" <<'PY'
import sys

try:
    import yaml
except ModuleNotFoundError as exc:
    print(f"error: {exc}. Install PyYAML to validate release-matrix.yaml", file=sys.stderr)
    sys.exit(1)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def require_string(mapping, path):
    current = mapping
    for key in path:
        if not isinstance(current, dict) or key not in current:
            fail(f"missing required field: {'.'.join(path)}")
        current = current[key]
    if not isinstance(current, str) or not current.strip():
        fail(f"field must be a non-empty string: {'.'.join(path)}")
    return current.strip()


with open(sys.argv[1], "r", encoding="utf-8") as stream:
    document = yaml.safe_load(stream)

if not isinstance(document, dict):
    fail("release matrix must be a YAML mapping at the document root")

selected_track = require_string(document, ["nvidia", "selectedTrack"])
if selected_track not in {"production", "lts"}:
    fail(f"unsupported nvidia.selectedTrack '{selected_track}'")

upstream_release = require_string(document, ["nvidia", "upstreamOpenModuleTag"])
upstream_source_release = require_string(document, ["nvidia", "upstreamOpenModuleSource", "release"])
if upstream_release != upstream_source_release:
    fail(
        "mismatch: nvidia.upstreamOpenModuleTag "
        f"'{upstream_release}' != nvidia.upstreamOpenModuleSource.release '{upstream_source_release}'"
    )

upstream_repository = require_string(document, ["nvidia", "upstreamOpenModuleSource", "repository"])
upstream_commit = require_string(document, ["nvidia", "upstreamOpenModuleSource", "commit"])
donor_branch = require_string(document, ["nvidia", "donorPatchSource", "branch"])
donor_base_release = require_string(document, ["nvidia", "donorPatchSource", "donorBaseRelease"])
donor_base_commit = require_string(document, ["nvidia", "donorPatchSource", "baseCommit"])
donor_patch_commit = require_string(document, ["nvidia", "donorPatchSource", "patchCommit"])
donor_branch_head_commit = require_string(document, ["nvidia", "donorPatchSource", "branchHeadCommit"])
diff_url = require_string(document, ["nvidia", "donorPatchSource", "compareDiffURL"])

if donor_base_release != upstream_release:
    fail(
        "mismatch: nvidia.donorPatchSource.donorBaseRelease "
        f"'{donor_base_release}' != nvidia.upstreamOpenModuleTag '{upstream_release}'"
    )

if donor_base_commit != upstream_commit:
    fail(
        "mismatch: nvidia.donorPatchSource.baseCommit "
        f"'{donor_base_commit}' != nvidia.upstreamOpenModuleSource.commit '{upstream_commit}'"
    )

if donor_base_commit == donor_patch_commit:
    fail("mismatch: nvidia.donorPatchSource.patchCommit must differ from nvidia.donorPatchSource.baseCommit")

values = [
    selected_track,
    upstream_repository,
    upstream_release,
    upstream_commit,
    donor_branch,
    donor_base_release,
    donor_base_commit,
    donor_patch_commit,
    donor_branch_head_commit,
    diff_url,
]

for value in values:
    print(value)
PY
)"

mapfile -t matrix_values < <(printf '%s\n' "$matrix_output")

selected_track="${matrix_values[0]}"
upstream_repo_url="${matrix_values[1]}"
upstream_release="${matrix_values[2]}"
upstream_commit="${matrix_values[3]}"
donor_branch="${matrix_values[4]}"
donor_base_release="${matrix_values[5]}"
donor_base_commit="${matrix_values[6]}"
donor_patch_commit="${matrix_values[7]}"
donor_branch_head_commit="${matrix_values[8]}"
diff_url="${matrix_values[9]}"

archive_path="$workspace/open-gpu-kernel-modules-${upstream_release}.tar.gz"
commit_archive_path="$workspace/open-gpu-kernel-modules-${upstream_commit}.tar.gz"
diff_path="$workspace/p2p.diff"
checkout_dir="$workspace/open-gpu-kernel-modules-${upstream_release}"
commit_checkout_dir="$workspace/open-gpu-kernel-modules-${upstream_commit}"

curl -fsSL "$diff_url" -o "$diff_path"
curl -fsSL "${upstream_repo_url}/archive/refs/tags/${upstream_release}.tar.gz" -o "$archive_path"
curl -fsSL "${upstream_repo_url}/archive/${upstream_commit}.tar.gz" -o "$commit_archive_path"
tar -xzf "$archive_path" -C "$workspace"
tar -xzf "$commit_archive_path" -C "$workspace"

if [ ! -d "$checkout_dir" ]; then
  echo "error: extracted upstream source directory missing at '$checkout_dir'" >&2
  exit 1
fi

if [ ! -d "$commit_checkout_dir" ]; then
  echo "error: extracted pinned-commit source directory missing at '$commit_checkout_dir'" >&2
  exit 1
fi

if ! diff -qr "$checkout_dir" "$commit_checkout_dir" >/dev/null; then
  echo "error: upstream release '$upstream_release' source does not match pinned commit '$upstream_commit'" >&2
  exit 1
fi

patch --strip=1 --directory="$checkout_dir" --dry-run --input="$diff_path" >/dev/null

printf 'validated patch apply against NVIDIA %s tag %s\n' "$selected_track" "$upstream_release"
printf 'validated upstream release source matches pinned commit: %s\n' "$upstream_commit"
printf 'validated donor branch: %s\n' "$donor_branch"
printf 'validated donor base release: %s\n' "$donor_base_release"
printf 'validated donor base commit: %s\n' "$donor_base_commit"
printf 'validated donor patch commit: %s\n' "$donor_patch_commit"
printf 'validated donor branch head commit: %s\n' "$donor_branch_head_commit"
printf 'validated compare diff: %s\n' "$diff_url"

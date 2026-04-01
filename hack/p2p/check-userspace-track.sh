#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <path-to-release-matrix.yaml>" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  usage
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$(dirname "$script_dir")")"
matrix_path="$1"

if [ ! -f "$matrix_path" ]; then
  echo "error: release matrix not found at '$matrix_path'" >&2
  exit 1
fi

python3 - "$matrix_path" "$repo_root" <<'PY'
import re
import sys
from pathlib import Path

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


def load_vars(path: Path):
    values = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"')
    return values


def family_branch(version: str) -> str:
    match = re.match(r"(\d+)", version)
    if not match:
        fail(f"unable to determine NVIDIA driver family from '{version}'")
    return match.group(1)


def track_from_extension_name(name: str) -> str:
    for candidate in ("production", "lts"):
        if name.endswith(f"-{candidate}"):
            return candidate
    fail(f"unable to determine toolkit track from extension name '{name}'")


matrix_path = Path(sys.argv[1])
repo_root = Path(sys.argv[2])

with matrix_path.open("r", encoding="utf-8") as stream:
    document = yaml.safe_load(stream)

if not isinstance(document, dict):
    fail("release matrix must be a YAML mapping at the document root")

selected_track = require_string(document, ["nvidia", "selectedTrack"])
if selected_track != "lts":
    fail(f"mismatch: nvidia.selectedTrack '{selected_track}' != 'lts'")

upstream_open_module_tag = require_string(document, ["nvidia", "upstreamOpenModuleTag"])
open_module_name = require_string(document, ["nvidia", "officialOpenModuleExtension", "name"])
open_module_ref = require_string(document, ["nvidia", "officialOpenModuleExtension", "ref"])
toolkit_name = require_string(document, ["nvidia", "officialUserspaceToolkitExtension", "name"])
toolkit_ref = require_string(document, ["nvidia", "officialUserspaceToolkitExtension", "ref"])
toolkit_track = require_string(document, ["nvidia", "officialUserspaceToolkitExtension", "track"])
recorded_family_branch = require_string(document, ["nvidia", "officialUserspaceToolkitExtension", "driverFamilyBranch"])

if "@" in open_module_ref:
    fail(f"mismatch: open module ref '{open_module_ref}' must be tag-only; digest belongs in a separate field")
if "@" in toolkit_ref:
    fail(f"mismatch: toolkit ref '{toolkit_ref}' must be tag-only; digest belongs in a separate field")

vars_yaml = load_vars(repo_root / "nvidia-gpu" / "vars.yaml")
toolkit_track_vars = load_vars(repo_root / "nvidia-gpu" / "nvidia-container-toolkit" / selected_track / "vars.yaml")

driver_key = f"NVIDIA_DRIVER_{selected_track.upper()}_VERSION"
resolved_driver_version = vars_yaml.get(driver_key)
if not resolved_driver_version:
    fail(f"missing driver key '{driver_key}' in {repo_root / 'nvidia-gpu' / 'vars.yaml'}")
if resolved_driver_version != upstream_open_module_tag:
    fail(
        "mismatch: local upstream track metadata resolved "
        f"{driver_key}='{resolved_driver_version}' but matrix pins '{upstream_open_module_tag}'"
    )

expected_template = f"{{{{ .{driver_key} }}}}-{{{{ .CONTAINER_TOOLKIT_VERSION }}}}"
template_version = toolkit_track_vars.get("VERSION")
if template_version != expected_template:
    fail(
        "mismatch: local userspace template for track "
        f"'{selected_track}' is '{template_version}' but expected '{expected_template}'"
    )

if open_module_name != "siderolabs/nvidia-open-gpu-kernel-modules-lts":
    fail(
        "mismatch: official open module extension name "
        f"'{open_module_name}' does not match the stock LTS extension name"
    )

derived_track = track_from_extension_name(toolkit_name)
if toolkit_track != selected_track:
    fail(
        "mismatch: matrix toolkit track "
        f"'{toolkit_track}' does not match selected track '{selected_track}'"
    )
if derived_track != selected_track:
    fail(
        "mismatch: toolkit extension name "
        f"'{toolkit_name}' resolves to track '{derived_track}' instead of '{selected_track}'"
    )

tag = toolkit_ref.rsplit(":", 1)[-1]
toolkit_driver_version = tag.split("-", 1)[0]
module_family = family_branch(upstream_open_module_tag)
toolkit_family = family_branch(toolkit_driver_version)

if toolkit_family != module_family:
    fail(
        "mismatch: stock toolkit driver family "
        f"'{toolkit_family}' from ref '{toolkit_ref}' does not match selected module family '{module_family}'"
    )
if recorded_family_branch != module_family:
    fail(
        "mismatch: matrix recorded toolkit driver family "
        f"'{recorded_family_branch}' does not match selected module family '{module_family}'"
    )

print(f"validated selected track: {selected_track}")
print(f"validated open module extension: {open_module_name}")
print(f"validated vars key: {driver_key}={resolved_driver_version}")
print(f"validated toolkit template: {template_version}")
print(f"validated stock toolkit track: {toolkit_track}")
print(f"validated stock toolkit family branch: {toolkit_family}")
PY

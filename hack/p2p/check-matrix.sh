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

python3 - "$matrix_path" <<'PY'
import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError as exc:
    print(f"error: {exc}. Install PyYAML to validate release-matrix.yaml", file=sys.stderr)
    sys.exit(1)


EXPECTED = {
    "targetTalosVersion": "v1.13.0-beta.1",
    "targetTalosMinor": "v1.13",
    "kernelVersion": "6.18.19-talos",
    "kubernetesVersion": "v1.36.0-beta.0",
    "kubernetesMinor": "v1.36",
    "arch": "amd64",
    "osImage": "Talos (v1.13.0-beta.1)",
    "selectedTrack": "production",
    "upstreamTag": "595.58.03",
    "upstreamRepository": "https://github.com/NVIDIA/open-gpu-kernel-modules",
    "upstreamReleaseURL": "https://github.com/NVIDIA/open-gpu-kernel-modules/releases/tag/595.58.03",
    "upstreamCommit": "db0c4e65c8e34c678d745ddb1317f53f90d1072b",
    "donorRepository": "https://github.com/aikitoria/open-gpu-kernel-modules",
    "donorBranch": "595.58.03-p2p",
    "donorBaseRelease": "595.58.03",
    "donorBaseCommit": "db0c4e65c8e34c678d745ddb1317f53f90d1072b",
    "donorPatchCommit": "2b75b4991f506526ff6dbd179d61e5f8797ebb15",
    "donorBranchHeadCommit": "6dd6ba34a4abfb3761797b26102094b856b01edd",
    "donorCompareDiffURL": "https://github.com/aikitoria/open-gpu-kernel-modules/compare/db0c4e65c8e34c678d745ddb1317f53f90d1072b...2b75b4991f506526ff6dbd179d61e5f8797ebb15.diff",
    "openModuleName": "siderolabs/nvidia-open-gpu-kernel-modules-production",
    "openModuleRef": "ghcr.io/siderolabs/nvidia-open-gpu-kernel-modules-production:595.58.03-v1.13.0-beta.1",
    "openModuleDigest": "sha256:92961aefa1f61a185cf14b6878b3f5d818f0cc6bd631094cbb07c26cb68c332f",
    "toolkitName": "siderolabs/nvidia-container-toolkit-production",
    "toolkitRef": "ghcr.io/siderolabs/nvidia-container-toolkit-production:595.58.03-v1.19.0",
    "toolkitDigest": "sha256:95039cbda2db18ec8bb5581eb55737af49be0ca0537df3f9b7db6aa916fcd5c6",
    "toolkitTrack": "production",
    "toolkitDriverFamilyBranch": "595",
    "toolkitSourceRepository": "https://github.com/siderolabs/extensions",
    "rollbackInstaller": "factory.talos.dev/installer/383ff20982d317df4085095c792d4927aa9cc88c56d7f67242f8c91d8e6b3142:v1.12.6",
    "repositoryUpstream": "siderolabs/extensions",
}

EXPECTED_ABORT_CODES = {
    "donor_patch_no_longer_ports_cleanly",
    "missing_rollback_image",
    "stock_toolkit_track_mismatch",
}

EXPECTED_VERIFICATION_COMMANDS = {
    "matrixValidationCommand": "bash hack/p2p/check-matrix.sh docs/release-matrix.yaml",
    "donorPatchValidationCommand": "bash hack/p2p/check-patch-apply.sh docs/release-matrix.yaml",
    "userspaceTrackValidationCommand": "bash hack/p2p/check-userspace-track.sh docs/release-matrix.yaml",
}

STALE_ROOT_KEYS = {"canaryDeploymentName", "canaryLabel", "manifestSkew", "task", "planItem", "generatedBy"}
STALE_TERMS = ("wozeparrot", "legacyfix")


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def get_path(data, path):
    current = data
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def require_string(path, expected=None):
    value = get_path(document, path)
    dotted = ".".join(path)
    if not isinstance(value, str) or not value.strip():
        errors.append(f"missing or empty field: {dotted}")
        return None
    value = value.strip()
    if expected is not None and value != expected:
        errors.append(f"field {dotted}='{value}' does not match expected '{expected}'")
    return value


def require_int(path, expected=None):
    value = get_path(document, path)
    dotted = ".".join(path)
    if not isinstance(value, int):
        errors.append(f"field must be an integer: {dotted}")
        return None
    if expected is not None and value != expected:
        errors.append(f"field {dotted}={value} does not match expected {expected}")
    return value


def require_mapping(path):
    value = get_path(document, path)
    dotted = ".".join(path)
    if not isinstance(value, dict):
        errors.append(f"field must be a mapping: {dotted}")
        return None
    return value


def require_null_or_non_empty_string(path):
    value = get_path(document, path)
    dotted = ".".join(path)
    if value is None:
        return
    if not isinstance(value, str) or not value.strip():
        errors.append(f"field must be null or a non-empty string: {dotted}")


def require_sha256(path, expected):
    value = require_string(path, expected)
    if value and not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        errors.append(f"field {'.'.join(path)} must be a sha256 digest")


matrix_path = Path(sys.argv[1])
raw_text = matrix_path.read_text(encoding="utf-8")

with matrix_path.open("r", encoding="utf-8") as stream:
    document = yaml.safe_load(stream)

errors = []

if not isinstance(document, dict):
    fail("release matrix must be a YAML mapping at the document root")
    sys.exit(1)

if document.get("schemaVersion") != 1:
    errors.append("schemaVersion must be 1")

require_string(["baseGpuNode"])
require_string(["baseGpuNodeInternalIP"])
require_string(["targetTalosVersion"], EXPECTED["targetTalosVersion"])
require_string(["targetTalosMinor"], EXPECTED["targetTalosMinor"])
require_string(["kernelVersion"], EXPECTED["kernelVersion"])
require_string(["kubernetesVersion"], EXPECTED["kubernetesVersion"])
require_string(["kubernetesMinor"], EXPECTED["kubernetesMinor"])
require_string(["arch"], EXPECTED["arch"])
require_string(["osImage"], EXPECTED["osImage"])

target_talos_version = get_path(document, ["targetTalosVersion"])
target_talos_minor = get_path(document, ["targetTalosMinor"])
if isinstance(target_talos_version, str) and isinstance(target_talos_minor, str) and not target_talos_version.startswith(target_talos_minor):
    errors.append("targetTalosVersion must start with targetTalosMinor")

kubernetes_version = get_path(document, ["kubernetesVersion"])
kubernetes_minor = get_path(document, ["kubernetesMinor"])
if isinstance(kubernetes_version, str) and isinstance(kubernetes_minor, str) and not kubernetes_version.startswith(kubernetes_minor):
    errors.append("kubernetesVersion must start with kubernetesMinor")

for stale_key in sorted(STALE_ROOT_KEYS):
    if stale_key in document:
        errors.append(f"stale root key must be removed: {stale_key}")

lower_text = raw_text.lower()
for stale_term in STALE_TERMS:
    if stale_term in lower_text:
        errors.append(f"stale term must not appear in release matrix: {stale_term}")

nvidia = require_mapping(["nvidia"])
if nvidia is not None:
    require_string(["nvidia", "selectedTrack"], EXPECTED["selectedTrack"])
    selected_track_reason = require_string(["nvidia", "selectedTrackReason"])
    if selected_track_reason and "stock" not in selected_track_reason.lower():
        errors.append("nvidia.selectedTrackReason must explain that userspace/toolkit remain stock")
    require_string(["nvidia", "upstreamOpenModuleTag"], EXPECTED["upstreamTag"])
    require_string(["nvidia", "upstreamOpenModuleSource", "repository"], EXPECTED["upstreamRepository"])
    require_string(["nvidia", "upstreamOpenModuleSource", "release"], EXPECTED["upstreamTag"])
    require_string(["nvidia", "upstreamOpenModuleSource", "releaseURL"], EXPECTED["upstreamReleaseURL"])
    require_string(["nvidia", "upstreamOpenModuleSource", "commit"], EXPECTED["upstreamCommit"])

    if get_path(document, ["nvidia", "tinygradPatchSource"]) is not None:
        errors.append("nvidia.tinygradPatchSource must be removed in favor of nvidia.donorPatchSource")

    donor = require_mapping(["nvidia", "donorPatchSource"])
    if donor is not None:
        require_string(["nvidia", "donorPatchSource", "repository"], EXPECTED["donorRepository"])
        require_string(["nvidia", "donorPatchSource", "branch"], EXPECTED["donorBranch"])
        require_string(["nvidia", "donorPatchSource", "donorBaseRelease"], EXPECTED["donorBaseRelease"])
        lineage = require_string(["nvidia", "donorPatchSource", "lineage"])
        if lineage:
            lineage_lower = lineage.lower()
            if "donor patch" not in lineage_lower or EXPECTED["upstreamTag"] not in lineage:
                errors.append(
                    "nvidia.donorPatchSource.lineage must describe the donor patch flow onto the selected "
                    f"NVIDIA {EXPECTED['upstreamTag']} {EXPECTED['selectedTrack']} base"
                )
        require_string(["nvidia", "donorPatchSource", "baseCommit"], EXPECTED["donorBaseCommit"])
        require_string(["nvidia", "donorPatchSource", "patchCommit"], EXPECTED["donorPatchCommit"])
        require_string(["nvidia", "donorPatchSource", "branchHeadCommit"], EXPECTED["donorBranchHeadCommit"])
        require_string(["nvidia", "donorPatchSource", "compareDiffURL"], EXPECTED["donorCompareDiffURL"])

    require_string(["nvidia", "officialOpenModuleExtension", "name"], EXPECTED["openModuleName"])
    open_module_ref = require_string(["nvidia", "officialOpenModuleExtension", "ref"], EXPECTED["openModuleRef"])
    require_sha256(["nvidia", "officialOpenModuleExtension", "digest"], EXPECTED["openModuleDigest"])
    if open_module_ref and "@" in open_module_ref:
        errors.append("nvidia.officialOpenModuleExtension.ref must be tag-only; store digest separately")

    require_string(["nvidia", "officialUserspaceToolkitExtension", "name"], EXPECTED["toolkitName"])
    toolkit_ref = require_string(["nvidia", "officialUserspaceToolkitExtension", "ref"], EXPECTED["toolkitRef"])
    require_sha256(["nvidia", "officialUserspaceToolkitExtension", "digest"], EXPECTED["toolkitDigest"])
    require_string(["nvidia", "officialUserspaceToolkitExtension", "track"], EXPECTED["toolkitTrack"])
    require_string(["nvidia", "officialUserspaceToolkitExtension", "driverFamilyBranch"], EXPECTED["toolkitDriverFamilyBranch"])
    require_string(["nvidia", "officialUserspaceToolkitExtension", "sourceRepository"], EXPECTED["toolkitSourceRepository"])
    if toolkit_ref and "@" in toolkit_ref:
        errors.append("nvidia.officialUserspaceToolkitExtension.ref must be tag-only; store digest separately")

artifacts = require_mapping(["artifacts"])
if artifacts is not None:
    require_string(["artifacts", "currentRollbackInstallerImage", "ref"], EXPECTED["rollbackInstaller"])
    require_string(["artifacts", "currentRollbackInstallerImage", "discoverableFrom"])
    require_null_or_non_empty_string(["artifacts", "customKernelImage"])
    require_null_or_non_empty_string(["artifacts", "customKernelDigest"])
    require_null_or_non_empty_string(["artifacts", "customPkgImage"])
    require_null_or_non_empty_string(["artifacts", "customPkgDigest"])
    require_null_or_non_empty_string(["artifacts", "customSysextImage"])
    require_null_or_non_empty_string(["artifacts", "customSysextDigest"])
    require_null_or_non_empty_string(["artifacts", "customInstallerBaseImage"])
    require_null_or_non_empty_string(["artifacts", "customInstallerBaseDigest"])
    require_null_or_non_empty_string(["artifacts", "customInstallerImage"])
    require_null_or_non_empty_string(["artifacts", "customInstallerDigest"])

abort_conditions = document.get("abortConditions")
if not isinstance(abort_conditions, list) or not abort_conditions:
    errors.append("abortConditions must be a non-empty list")
else:
    seen_codes = set()
    for index, condition in enumerate(abort_conditions, start=1):
        if not isinstance(condition, dict):
            errors.append(f"abortConditions[{index}] must be a mapping")
            continue
        code = condition.get("code")
        stop_when = condition.get("stopWhen")
        if not isinstance(code, str) or not code.strip():
            errors.append(f"abortConditions[{index}].code must be a non-empty string")
            continue
        seen_codes.add(code.strip())
        if not isinstance(stop_when, str) or not stop_when.strip():
            errors.append(f"abortConditions[{index}].stopWhen must be a non-empty string")
    missing_codes = sorted(EXPECTED_ABORT_CODES - seen_codes)
    if missing_codes:
        errors.append("abortConditions missing required codes: " + ", ".join(missing_codes))

verification = require_mapping(["verification"])
if verification is not None:
    for key, expected_value in EXPECTED_VERIFICATION_COMMANDS.items():
        require_string(["verification", key], expected_value)
    require_string(["verification", "rollbackImageDiscoveryCommand"])

repository = require_mapping(["repository"])
if repository is not None:
    require_string(["repository", "origin"])
    require_string(["repository", "upstream"], EXPECTED["repositoryUpstream"])

if errors:
    for error in errors:
        fail(error)
    sys.exit(1)

print(f"validated release matrix: {matrix_path}")
print(f"validated selected track: {document['nvidia']['selectedTrack']}")
print(f"validated NVIDIA production tag: {document['nvidia']['upstreamOpenModuleTag']}")
print(f"validated rollback image: {document['artifacts']['currentRollbackInstallerImage']['ref']}")
PY

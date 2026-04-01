import json
import sys

GROUPS = {"defconfig", "kspp"}

IGNORE_VIOLATIONS = {
    "CONFIG_MODULES",
    "CONFIG_IA32_EMULATION",
    "CONFIG_COMPAT",
    "CONFIG_INIT_ON_FREE_DEFAULT_ON",
    "CONFIG_BINFMT_MISC",
    "CONFIG_WERROR",
    "CONFIG_DEBUG_VIRTUAL",
    "CONFIG_STATIC_USERMODEHELPER",
    "CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY",
    "CONFIG_RANDSTRUCT_FULL",
    "CONFIG_RANDSTRUCT_PERFORMANCE",
    "CONFIG_UBSAN_TRAP",
    "CONFIG_UBSAN_LOCAL_BOUNDS",
    "CONFIG_CFI_CLANG",
    "CONFIG_CFI_PERMISSIVE",
    "CONFIG_SECURITY_SELINUX_DEVELOP",
    "CONFIG_SPECULATION_MITIGATIONS",
    "CONFIG_EFI_DISABLE_PCI_DMA",
    "CONFIG_INET_DIAG",
    "CONFIG_IOMMU_DEFAULT_DMA_STRICT",
    "CONFIG_PROC_MEM_NO_FORCE",
    "CONFIG_GCC_PLUGIN_LATENT_ENTROPY",
}

IGNORE_VIOLATIONS_BY_ARCH = {
    "arm64": {
        "CONFIG_DEFAULT_MMAP_MIN_ADDR",
        "CONFIG_LSM_MMAP_MIN_ADDR",
        "CONFIG_RODATA_FULL_DEFAULT_ENABLED",
        "CONFIG_KASAN_HW_TAGS",
    },
    "amd64": {
        "CONFIG_CFI_AUTO_DEFAULT",
    },
}


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <arch>")
        sys.exit(1)

    arch = sys.argv[1]
    violations = json.load(sys.stdin)
    violations = [
        item for item in violations if item["check_result"].startswith("FAIL")
    ]
    violations = [item for item in violations if item["decision"] in GROUPS]

    ignored = set(IGNORE_VIOLATIONS)
    ignored.update(IGNORE_VIOLATIONS_BY_ARCH[arch])
    violations = [item for item in violations if item["option_name"] not in ignored]

    if not violations:
        sys.exit(0)

    print(
        "{:^45}|{:^13}|{:^10}|{:^20}".format(
            "option name", "desired val", "decision", "reason"
        )
    )
    print("=" * 91)

    for item in violations:
        print(
            "{:<45}|{:^13}|{:^10}|{:^20}".format(
                item["option_name"],
                item["desired_val"],
                item["decision"],
                item["reason"],
            )
        )

    sys.exit(1)


if __name__ == "__main__":
    main()

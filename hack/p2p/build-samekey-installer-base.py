#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


def run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    capture: bool = False,
    env: dict[str, str] | None = None,
) -> str:
    print(f"+ {' '.join(cmd)}")
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )

    return result.stdout if capture else ""


def run_bytes(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> bytes:
    print(f"+ {' '.join(cmd)}")
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        check=True,
        text=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    return result.stdout


def pull_image(image: str, *, attempts: int = 5, delay_seconds: int = 5) -> None:
    for attempt in range(1, attempts + 1):
        try:
            run(["docker", "pull", image])
            return
        except subprocess.CalledProcessError:
            if attempt == attempts:
                raise

            print(
                f"docker pull failed for {image} "
                f"(attempt {attempt}/{attempts}); retrying in {delay_seconds}s"
            )
            time.sleep(delay_seconds)


def push_image(image: str, *, attempts: int = 5, delay_seconds: int = 5) -> None:
    for attempt in range(1, attempts + 1):
        try:
            run(["docker", "push", image])
            return
        except subprocess.CalledProcessError:
            if attempt == attempts:
                raise

            print(
                f"docker push failed for {image} "
                f"(attempt {attempt}/{attempts}); retrying in {delay_seconds}s"
            )
            time.sleep(delay_seconds)


@dataclass
class CpioEntry:
    name: str
    mode: int
    uid: int
    gid: int
    nlink: int
    mtime: int
    devmajor: int
    devminor: int
    rdevmajor: int
    rdevminor: int
    data: bytes


def get_image_layers(image_tar_path: Path) -> list[str]:
    with tarfile.open(image_tar_path) as image_tar:
        manifest_file = image_tar.extractfile("manifest.json")
        if manifest_file is None:
            raise RuntimeError(f"manifest.json missing in {image_tar_path}")
        manifest = json.load(manifest_file)

    return manifest[0]["Layers"]


def extract_file_from_image(
    image_tar_path: Path, image_path: str, output_path: Path
) -> None:
    expected_path = str(PurePosixPath(image_path))

    with tarfile.open(image_tar_path) as image_tar:
        for layer_name in reversed(get_image_layers(image_tar_path)):
            layer_file = image_tar.extractfile(layer_name)
            if layer_file is None:
                continue

            with tarfile.open(fileobj=layer_file) as layer_tar:
                member = None
                for candidate in layer_tar.getmembers():
                    if str(PurePosixPath(candidate.name)) == expected_path:
                        member = candidate
                        break
                if member is None:
                    continue

                extracted = layer_tar.extractfile(member)
                if extracted is None:
                    raise RuntimeError(
                        f"failed to extract {image_path} from {image_tar_path}"
                    )

                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(extracted.read())
                output_path.chmod(member.mode or 0o644)

                return

    raise RuntimeError(f"unable to find {image_path} in {image_tar_path}")


def extract_single_layer_image(image_tar_path: Path, output_dir: Path) -> None:
    layers = get_image_layers(image_tar_path)
    if len(layers) != 1:
        raise RuntimeError(
            f"expected a single-layer image for {image_tar_path}, found {len(layers)}"
        )

    with tarfile.open(image_tar_path) as image_tar:
        layer_file = image_tar.extractfile(layers[0])
        if layer_file is None:
            raise RuntimeError(
                f"failed to read layer {layers[0]} from {image_tar_path}"
            )

        with tarfile.open(fileobj=layer_file) as layer_tar:
            layer_tar.extractall(output_dir)


def parse_newc_archive(archive_path: Path) -> tuple[list[CpioEntry], bytes]:
    entries: list[CpioEntry] = []

    with archive_path.open("rb") as stream:
        while True:
            header = stream.read(110)
            if not header:
                break
            if header[:6] != b"070701":
                raise RuntimeError(
                    f"unexpected cpio magic {header[:6]!r} in {archive_path}"
                )

            mode = int(header[14:22], 16)
            uid = int(header[22:30], 16)
            gid = int(header[30:38], 16)
            nlink = int(header[38:46], 16)
            mtime = int(header[46:54], 16)
            filesize = int(header[54:62], 16)
            devmajor = int(header[62:70], 16)
            devminor = int(header[70:78], 16)
            rdevmajor = int(header[78:86], 16)
            rdevminor = int(header[86:94], 16)
            namesize = int(header[94:102], 16)

            raw_name = stream.read(namesize)
            padding = (4 - ((110 + namesize) % 4)) % 4
            if padding:
                stream.read(padding)

            name = raw_name[:-1].decode("utf-8")
            data = stream.read(filesize)
            padding = (4 - (filesize % 4)) % 4
            if padding:
                stream.read(padding)

            entries.append(
                CpioEntry(
                    name=name,
                    mode=mode,
                    uid=uid,
                    gid=gid,
                    nlink=nlink,
                    mtime=mtime,
                    devmajor=devmajor,
                    devminor=devminor,
                    rdevmajor=rdevmajor,
                    rdevminor=rdevminor,
                    data=data,
                )
            )

            if name == "TRAILER!!!":
                break

        trailing_data = stream.read()

    return entries, trailing_data


def write_newc_archive(
    entries: list[CpioEntry], archive_path: Path, trailing_data: bytes = b""
) -> None:
    with archive_path.open("wb") as stream:
        for entry in entries:
            namesize = len(entry.name.encode("utf-8")) + 1
            header = (
                "070701"
                f"{0:08x}"
                f"{entry.mode:08x}"
                f"{entry.uid:08x}"
                f"{entry.gid:08x}"
                f"{entry.nlink:08x}"
                f"{entry.mtime:08x}"
                f"{len(entry.data):08x}"
                f"{entry.devmajor:08x}"
                f"{entry.devminor:08x}"
                f"{entry.rdevmajor:08x}"
                f"{entry.rdevminor:08x}"
                f"{namesize:08x}"
                f"{0:08x}"
            ).encode("ascii")
            stream.write(header)
            stream.write(entry.name.encode("utf-8") + b"\x00")
            stream.write(b"\x00" * ((4 - ((110 + namesize) % 4)) % 4))
            stream.write(entry.data)
            stream.write(b"\x00" * ((4 - (len(entry.data) % 4)) % 4))

        stream.write(trailing_data)


def extract_string_section(binary_path: Path, section: str, output_path: Path) -> str:
    run(["objcopy", f"--dump-section", f"{section}={output_path}", str(binary_path)])
    return output_path.read_text(encoding="utf-8").strip()


def extract_binary_section(binary_path: Path, section: str, output_path: Path) -> bytes:
    run(["objcopy", f"--dump-section", f"{section}={output_path}", str(binary_path)])
    return output_path.read_bytes()


def get_section_vma(binary_path: Path, section: str) -> str:
    objdump_output = run(["objdump", "-h", str(binary_path)], capture=True)

    for line in objdump_output.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] == section:
            return f"0x{parts[3]}"

    raise RuntimeError(
        f"unable to determine VMA for section {section} in {binary_path}"
    )


def copy_from_container_image(image: str, source_path: str, output_path: Path) -> None:
    container_name = f"samekey-copy-{os.getpid()}-{output_path.name.replace('.', '-')}"
    try:
        run(["docker", "create", "--name", container_name, image])
        output_path.parent.mkdir(parents=True, exist_ok=True)
        run(["docker", "cp", f"{container_name}:{source_path}", str(output_path)])
        copied_mode = stat.S_IMODE(output_path.stat().st_mode)
        output_path.chmod(copied_mode or 0o644)
    finally:
        run(["docker", "rm", "-f", container_name])


def extract_toolchain_assets(
    stock_installer_image: str,
    squashfs_tools_image_tar: Path,
    xz_image_tar: Path,
    zlib_image_tar: Path,
    zstd_image_tar: Path,
    work_dir: Path,
) -> tuple[Path, Path, Path, Path]:
    loader_path = work_dir / "usr/lib/ld-musl-x86_64.so.1"
    unsquashfs_path = work_dir / "bin/unsquashfs"
    mksquashfs_path = work_dir / "bin/mksquashfs"
    lib_dir = work_dir / "libdeps"

    copy_from_container_image(
        stock_installer_image, "/usr/lib/ld-musl-x86_64.so.1", loader_path
    )
    extract_file_from_image(
        squashfs_tools_image_tar, "usr/bin/unsquashfs", unsquashfs_path
    )
    extract_file_from_image(
        squashfs_tools_image_tar, "usr/bin/mksquashfs", mksquashfs_path
    )
    extract_file_from_image(
        xz_image_tar, "usr/lib/liblzma.so.5", lib_dir / "liblzma.so.5"
    )
    extract_file_from_image(zlib_image_tar, "usr/lib/libz.so.1", lib_dir / "libz.so.1")
    extract_file_from_image(
        zstd_image_tar, "usr/lib/libzstd.so.1", lib_dir / "libzstd.so.1"
    )

    for executable_path in (loader_path, unsquashfs_path, mksquashfs_path):
        executable_path.chmod(
            executable_path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        )

    return loader_path, unsquashfs_path, mksquashfs_path, lib_dir


def run_musl_tool(
    work_dir: Path,
    tool_name: str,
    args: list[str],
    *,
    capture: bool = False,
) -> str:
    return run(
        [
            str(work_dir / "usr/lib/ld-musl-x86_64.so.1"),
            str(work_dir / f"bin/{tool_name}"),
            *args,
        ],
        env={"LD_LIBRARY_PATH": str(work_dir / "libdeps")},
        capture=capture,
    )


def run_musl_tool_bytes(
    work_dir: Path,
    tool_name: str,
    args: list[str],
) -> bytes:
    return run_bytes(
        [
            str(work_dir / "usr/lib/ld-musl-x86_64.so.1"),
            str(work_dir / f"bin/{tool_name}"),
            *args,
        ],
        env={"LD_LIBRARY_PATH": str(work_dir / "libdeps")},
    )


def extract_modinfo_key(module_path: Path) -> str:
    modinfo_output = run(["modinfo", str(module_path)], capture=True)
    for line in modinfo_output.splitlines():
        if line.startswith("sig_key:"):
            return line.split(":", 1)[1].strip()
    raise RuntimeError(f"sig_key not found in modinfo for {module_path}")


@contextmanager
def managed_work_dir() -> Iterator[Path]:
    requested_work_dir = os.environ.get("WORK_DIR")
    keep_work_dir = os.environ.get("KEEP_WORKDIR", "").lower() in {
        "1",
        "true",
        "yes",
    }

    if requested_work_dir:
        work_dir = Path(requested_work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        print(f"using work dir: {work_dir}")
        yield work_dir
        return

    work_dir = Path(tempfile.mkdtemp(prefix="samekey-installer-base-"))
    print(f"work dir: {work_dir}")

    try:
        yield work_dir
    except Exception:
        print(f"preserving failed work dir: {work_dir}")
        raise
    else:
        if keep_work_dir:
            print(f"preserved work dir: {work_dir}")
        else:
            try:
                shutil.rmtree(work_dir)
            except PermissionError:
                print(f"preserved work dir due cleanup permissions: {work_dir}")


def main() -> None:
    stock_installer_image = os.environ.get(
        "STOCK_INSTALLER_BASE_IMAGE", "ghcr.io/siderolabs/installer-base:v1.12.6"
    )
    source_installer_image = os.environ.get("SOURCE_INSTALLER_IMAGE", "").strip()
    imager_image = os.environ.get("IMAGER_IMAGE", "ghcr.io/siderolabs/imager:v1.12.6")
    samekey_kernel_image = os.environ.get(
        "SAMEKEY_KERNEL_IMAGE",
        "ghcr.io/<your-org>/extensions-nvidia-p2p/kernel:v1.12.6-samekey",
    )
    squashfs_tools_image = os.environ.get(
        "SQUASHFS_TOOLS_IMAGE", "ghcr.io/siderolabs/squashfs-tools:v1.12.0"
    )
    xz_image = os.environ.get("XZ_IMAGE", "ghcr.io/siderolabs/xz:v1.12.0")
    zlib_image = os.environ.get("ZLIB_IMAGE", "ghcr.io/siderolabs/zlib:v1.12.0")
    zstd_image = os.environ.get("ZSTD_IMAGE", "ghcr.io/siderolabs/zstd:v1.12.0")
    output_image = os.environ.get(
        "OUTPUT_IMAGE",
        "ghcr.io/<your-org>/extensions-nvidia-p2p/installer-base:v1.12.6-samekey",
    )
    push_output = os.environ.get("PUSH_OUTPUT", "true").lower() not in {
        "0",
        "false",
        "no",
    }

    with managed_work_dir() as work_dir:
        image_tar_dir = work_dir / "image-tars"
        image_tar_dir.mkdir(parents=True, exist_ok=True)
        stock_installer_out_dir = work_dir / "stock-installer-out"
        stock_installer_out_dir.mkdir(parents=True, exist_ok=True)

        stock_installer_tar = stock_installer_out_dir / "installer-amd64.tar"
        samekey_kernel_image_tar = image_tar_dir / "samekey-kernel.tar"
        squashfs_tools_image_tar = image_tar_dir / "squashfs-tools.tar"
        xz_image_tar = image_tar_dir / "xz.tar"
        zlib_image_tar = image_tar_dir / "zlib.tar"
        zstd_image_tar = image_tar_dir / "zstd.tar"

        for image in [
            imager_image,
            stock_installer_image,
            samekey_kernel_image,
            squashfs_tools_image,
            xz_image,
            zlib_image,
            zstd_image,
        ]:
            pull_image(image)

        if source_installer_image:
            pull_image(source_installer_image)

        if source_installer_image:
            print(f"using source installer image: {source_installer_image}")
        else:
            run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-v",
                    f"{stock_installer_out_dir}:/out",
                    imager_image,
                    "installer",
                    "--platform=metal",
                    "--arch=amd64",
                ]
            )

            if not stock_installer_tar.exists():
                raise RuntimeError(
                    f"stock installer tar missing at {stock_installer_tar}"
                )

        image_map = {
            samekey_kernel_image: samekey_kernel_image_tar,
            squashfs_tools_image: squashfs_tools_image_tar,
            xz_image: xz_image_tar,
            zlib_image: zlib_image_tar,
            zstd_image: zstd_image_tar,
        }
        for image, tar_path in image_map.items():
            run(["docker", "image", "save", "-o", str(tar_path), image])

        loader_path, unsquashfs_path, mksquashfs_path, lib_dir = (
            extract_toolchain_assets(
                stock_installer_image,
                squashfs_tools_image_tar,
                xz_image_tar,
                zlib_image_tar,
                zstd_image_tar,
                work_dir,
            )
        )
        _ = (loader_path, unsquashfs_path, mksquashfs_path, lib_dir)

        stock_uki = work_dir / "stock-vmlinuz.efi"
        stock_initrd_zst = work_dir / "stock-initrd.zst"
        stock_uname = work_dir / "stock-uname.txt"
        stock_cmdline = work_dir / "stock-cmdline.bin"
        samekey_layer_dir = work_dir / "samekey-kernel-layer"

        if source_installer_image:
            copy_from_container_image(
                source_installer_image, "/usr/install/amd64/vmlinuz.efi", stock_uki
            )
        else:
            extract_file_from_image(
                stock_installer_tar, "usr/install/amd64/vmlinuz.efi", stock_uki
            )
        kernel_release = extract_string_section(stock_uki, ".uname", stock_uname)
        extract_binary_section(stock_uki, ".cmdline", stock_cmdline)
        cmdline_vma = get_section_vma(stock_uki, ".cmdline")
        linux_vma = get_section_vma(stock_uki, ".linux")
        initrd_vma = get_section_vma(stock_uki, ".initrd")
        run(
            [
                "objcopy",
                f"--dump-section",
                f".initrd={stock_initrd_zst}",
                str(stock_uki),
            ]
        )

        samekey_layer_dir.mkdir(parents=True, exist_ok=True)
        extract_single_layer_image(samekey_kernel_image_tar, samekey_layer_dir)

        samekey_vmlinuz = samekey_layer_dir / "boot/vmlinuz"
        samekey_modules_root = samekey_layer_dir / f"usr/lib/modules/{kernel_release}"
        if not samekey_vmlinuz.exists():
            raise RuntimeError(f"missing samekey kernel bzImage at {samekey_vmlinuz}")
        if not samekey_modules_root.exists():
            raise RuntimeError(
                f"missing samekey modules tree at {samekey_modules_root}"
            )

        stock_initrd_raw = work_dir / "stock-initrd.raw"
        run(
            [
                "zstd",
                "-q",
                "-d",
                "-f",
                str(stock_initrd_zst),
                "-o",
                str(stock_initrd_raw),
            ]
        )
        cpio_entries, trailing_data = parse_newc_archive(stock_initrd_raw)

        stock_init_path = work_dir / "init"
        stock_rootfs_sqsh = work_dir / "rootfs.sqsh"
        for entry in cpio_entries:
            if entry.name == "init":
                stock_init_path.write_bytes(entry.data)
                stock_init_path.chmod(entry.mode)
            elif entry.name == "rootfs.sqsh":
                stock_rootfs_sqsh.write_bytes(entry.data)
                stock_rootfs_sqsh.chmod(entry.mode)

        if not stock_init_path.exists() or not stock_rootfs_sqsh.exists():
            raise RuntimeError("stock initrd is missing init or rootfs.sqsh")

        rootfs_dir = work_dir / "rootfs"
        run_musl_tool(
            work_dir,
            "unsquashfs",
            ["-no-xattrs", "-d", str(rootfs_dir), str(stock_rootfs_sqsh)],
        )

        target_modules_root = rootfs_dir / f"usr/lib/modules/{kernel_release}"
        if target_modules_root.exists():
            shutil.rmtree(target_modules_root)
        shutil.copytree(
            samekey_modules_root,
            target_modules_root,
            symlinks=True,
            copy_function=shutil.copy2,
        )

        rebuilt_rootfs_sqsh = work_dir / "rootfs-rebuilt.sqsh"
        if rebuilt_rootfs_sqsh.exists():
            rebuilt_rootfs_sqsh.unlink()
        run_musl_tool(
            work_dir,
            "mksquashfs",
            [
                str(rootfs_dir),
                str(rebuilt_rootfs_sqsh),
                "-comp",
                "zstd",
                "-Xcompression-level",
                "18",
                "-b",
                "131072",
                "-noappend",
                "-quiet",
            ],
        )

        rebuilt_entries: list[CpioEntry] = []
        for entry in cpio_entries:
            if entry.name == "rootfs.sqsh":
                rebuilt_entries.append(
                    CpioEntry(
                        name=entry.name,
                        mode=entry.mode,
                        uid=entry.uid,
                        gid=entry.gid,
                        nlink=entry.nlink,
                        mtime=entry.mtime,
                        devmajor=entry.devmajor,
                        devminor=entry.devminor,
                        rdevmajor=entry.rdevmajor,
                        rdevminor=entry.rdevminor,
                        data=rebuilt_rootfs_sqsh.read_bytes(),
                    )
                )
            else:
                rebuilt_entries.append(entry)

        rebuilt_initrd_raw = work_dir / "initrd-rebuilt.raw"
        rebuilt_initrd_zst = work_dir / "initrd-rebuilt.zst"
        rebuilt_initramfs_xz = work_dir / "initramfs-rebuilt.xz"
        write_newc_archive(rebuilt_entries, rebuilt_initrd_raw, trailing_data)
        run(
            [
                "zstd",
                "-q",
                "-19",
                "-f",
                str(rebuilt_initrd_raw),
                "-o",
                str(rebuilt_initrd_zst),
            ]
        )
        rebuilt_initramfs_xz.write_bytes(
            run_bytes(["xz", "-q", "-9", "-c", str(rebuilt_initrd_raw)])
        )

        rebuilt_uki = work_dir / "vmlinuz-samekey.efi"
        stripped_uki = work_dir / "stock-vmlinuz-stripped.efi"
        run(
            [
                "objcopy",
                "--remove-section",
                ".profile",
                "--remove-section",
                ".cmdline",
                "--remove-section",
                ".linux",
                "--remove-section",
                ".initrd",
                str(stock_uki),
                str(stripped_uki),
            ]
        )
        run(
            [
                "objcopy",
                "--add-section",
                f".cmdline={stock_cmdline}",
                "--change-section-vma",
                f".cmdline={cmdline_vma}",
                "--set-section-flags",
                ".cmdline=contents,alloc,load,readonly,data",
                "--add-section",
                f".linux={samekey_vmlinuz}",
                "--change-section-vma",
                f".linux={linux_vma}",
                "--set-section-flags",
                ".linux=contents,alloc,load,readonly,data",
                "--add-section",
                f".initrd={rebuilt_initrd_zst}",
                "--change-section-vma",
                f".initrd={initrd_vma}",
                "--set-section-flags",
                ".initrd=contents,alloc,load,readonly,data",
                str(stripped_uki),
                str(rebuilt_uki),
            ]
        )

        verify_linux = work_dir / "verify-linux"
        verify_initrd_zst = work_dir / "verify-initrd.zst"
        run(["objcopy", f"--dump-section", f".linux={verify_linux}", str(rebuilt_uki)])
        run(
            [
                "objcopy",
                f"--dump-section",
                f".initrd={verify_initrd_zst}",
                str(rebuilt_uki),
            ]
        )

        if verify_linux.read_bytes() != samekey_vmlinuz.read_bytes():
            raise RuntimeError(
                "rebuilt UKI .linux section does not match samekey kernel"
            )

        verify_initrd_raw = work_dir / "verify-initrd.raw"
        run(
            [
                "zstd",
                "-q",
                "-d",
                "-f",
                str(verify_initrd_zst),
                "-o",
                str(verify_initrd_raw),
            ]
        )
        verify_entries, _ = parse_newc_archive(verify_initrd_raw)
        verify_rootfs_sqsh = work_dir / "verify-rootfs.sqsh"
        for entry in verify_entries:
            if entry.name == "rootfs.sqsh":
                verify_rootfs_sqsh.write_bytes(entry.data)
                break
        if not verify_rootfs_sqsh.exists():
            raise RuntimeError("rebuilt initrd is missing rootfs.sqsh")

        verify_samekey_ahci = work_dir / "samekey-ahci.ko"
        verify_rebuilt_ahci = work_dir / "rebuilt-rootfs-ahci.ko"
        verify_samekey_ahci.write_bytes(
            (samekey_modules_root / "kernel/drivers/ata/ahci.ko").read_bytes()
        )
        rebuilt_ahci_output = run_musl_tool_bytes(
            work_dir,
            "unsquashfs",
            [
                "-cat",
                str(verify_rootfs_sqsh),
                f"usr/lib/modules/{kernel_release}/kernel/drivers/ata/ahci.ko",
            ],
        )
        verify_rebuilt_ahci.write_bytes(rebuilt_ahci_output)

        samekey_sig_key = extract_modinfo_key(verify_samekey_ahci)
        rebuilt_sig_key = extract_modinfo_key(verify_rebuilt_ahci)
        if samekey_sig_key != rebuilt_sig_key:
            raise RuntimeError(
                f"rebuilt rootfs module sig_key {rebuilt_sig_key} does not match samekey kernel sig_key {samekey_sig_key}"
            )

        build_context = work_dir / "installer-base-build"
        build_context.mkdir(parents=True, exist_ok=True)
        shutil.copy2(samekey_vmlinuz, build_context / "vmlinuz")
        shutil.copy2(rebuilt_initramfs_xz, build_context / "initramfs.xz")
        shutil.copy2(rebuilt_uki, build_context / "vmlinuz.efi")
        output_base_image = source_installer_image or stock_installer_image
        (build_context / "Dockerfile").write_text(
            f"FROM {output_base_image}\n"
            "COPY vmlinuz /usr/install/amd64/vmlinuz\n"
            "COPY initramfs.xz /usr/install/amd64/initramfs.xz\n"
            "COPY vmlinuz.efi /usr/install/amd64/vmlinuz.efi\n",
            encoding="utf-8",
        )

        run(["docker", "build", "--no-cache", "-t", output_image, str(build_context)])
        if push_output:
            push_image(output_image)

            inspect_output = run(
                ["docker", "buildx", "imagetools", "inspect", output_image],
                capture=True,
            )
            digest = ""
            for line in inspect_output.splitlines():
                if line.startswith("Digest:"):
                    digest = line.split(":", 1)[1].strip()
                    break

            if digest:
                print(f"samekey installer-base digest: {output_image}@{digest}")
            else:
                print(f"samekey installer-base image: {output_image}")
        else:
            print(f"samekey installer-base image (local only): {output_image}")


if __name__ == "__main__":
    main()

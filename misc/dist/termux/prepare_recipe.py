#!/usr/bin/env python3
"""Adapt a pinned Termux package recipe to an exact Godot 4.8 fork commit."""

import argparse
import difflib
import re
import runpy
from pathlib import Path


def refreshed_patch(root: Path, name: str, replacements: dict[str, str]) -> str:
    source = (root / name).read_text()
    patched = source
    for old, new in replacements.items():
        if old not in patched:
            raise SystemExit(f"Termux patch context changed in {name}: {old}")
        patched = patched.replace(old, new)
    return "".join(difflib.unified_diff(
        source.splitlines(keepends=True), patched.splitlines(keepends=True),
        fromfile=f"a/{name}", tofile=f"b/{name}",
    ))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("recipe", type=Path)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
        parser.error("Expected a SHA-256 checksum")
    if not re.fullmatch(r"https://github.com/[\w.-]+/[\w.-]+/archive/[0-9a-f]{40}\.tar\.gz", args.source_url):
        parser.error("Expected a GitHub archive pinned to a full commit SHA")

    root = Path(__file__).resolve().parents[3]
    version = runpy.run_path(str(root / "version.py"))
    package_version = f"{version['major']}.{version['minor']}.{version['patch']}"
    if version["status"] != "stable":
        package_version += "~" + version["status"]

    recipe = args.recipe / "build.sh"
    text = recipe.read_text()
    values = {
        "TERMUX_PKG_VERSION": f'"{package_version}"',
        "TERMUX_PKG_REVISION": "1",
        "TERMUX_PKG_SRCURL": f'"{args.source_url}"',
        "TERMUX_PKG_SHA256": args.sha256,
        "TERMUX_PKG_AUTO_UPDATE": "false",
        "TERMUX_PKG_LICENSE_FILE": '"LICENSE.txt"',
    }
    for key, value in values.items():
        line = f"{key}={value}"
        if re.search(rf"^{key}=", text, re.M):
            text = re.sub(rf"^{key}=.*$", lambda match: line, text, flags=re.M)
        else:
            text = line + "\n" + text

    # Godot 4.8 uses mbedTLS 4/TF-PSA-Crypto. The 4.7 recipe's system-mbedTLS
    # integration and _ret rename patch target the old, incompatible API.
    old = '\tto_unbundle+="mbedtls "\n'
    if old not in text:
        raise SystemExit("Pinned recipe's mbedTLS unbundle entry changed")
    text = text.replace(old, "")
    text = text.replace("\t\tudev=no \\\n", "\t\tudev=no \\\n\t\taccesskit=no \\\n")
    (args.recipe / "crypto_core.cpp.patch").unlink()
    # Refresh patches against 4.8's upgraded OpenXR loader, preserving the
    # existing Termux behavior while avoiding fuzzy patch application.
    (args.recipe / "platform_utils.hpp.patch").write_text(refreshed_patch(
        root, "thirdparty/openxr/src/common/platform_utils.hpp",
        {"#ifdef HAVE_SECURE_GETENV": "#if defined(HAVE_SECURE_GETENV) && !defined(__ANDROID__)"},
    ))
    android_log_patch = ""
    for name in ["android_utilities.h", "android_utilities.cpp", "loader_logger_recorders.hpp",
                 "loader_logger_recorders.cpp", "loader_logger.cpp"]:
        android_log_patch += refreshed_patch(
            root, "thirdparty/openxr/src/loader/" + name,
            {"#ifdef __ANDROID__": "#if defined(__ANDROID__) && !defined(__TERMUX__)"},
        )
    (args.recipe / "remove-android-log.patch").write_text(android_log_patch)
    directory_patch = args.recipe / "set_dir.patch"
    previous = re.split(
        r"^(?:diff --git a/thirdparty/openxr/|--- a/thirdparty/openxr/)",
        directory_patch.read_text(), flags=re.M,
    )[0]
    directory_patch.write_text(previous + refreshed_patch(
        root, "thirdparty/openxr/src/loader/manifest_file.cpp",
        {
            '#define FALLBACK_CONFIG_DIRS "/etc/xdg"': '#define FALLBACK_CONFIG_DIRS "@TERMUX_PREFIX@/etc/xdg"',
            '#define FALLBACK_DATA_DIRS "/usr/local/share:/usr/share"': '#define FALLBACK_DATA_DIRS "@TERMUX_PREFIX@/share"',
            '#define SYSCONFDIR "/etc"': '#define SYSCONFDIR "@TERMUX_PREFIX@/etc"',
        },
    ))
    wayland_patch = args.recipe / "wayland_thread.cpp.patch"
    wayland_patch.write_text(refreshed_patch(
        root, "platform/linuxbsd/wayland/wayland_thread.cpp",
        {
            "// Based on the wayland book's shared memory boilerplate":
                "#include <sys/ioctl.h>\n\n// Based on the wayland book's shared memory boilerplate",
            "int WaylandThread::_allocate_shm_file(size_t size) {": """int WaylandThread::_allocate_shm_file(size_t size) {
#ifdef __ANDROID__
    int fd, ret;
    long flags;
    fd = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return fd;
    ret = ioctl(fd, _IOW(0x77, 3, size_t), size);
    if (ret < 0)
        goto err;
    flags = fcntl(fd, F_GETFD);
    if (flags == -1)
        goto err;
    if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1)
        goto err;
    return fd;
err:
    close(fd);
    return -1;
#else""",
            "\t} while (retries > 0 && errno == EEXIST);\n\n\treturn -1;":
                "\t} while (retries > 0 && errno == EEXIST);\n\n\treturn -1;\n#endif",
        },
    ))
    recipe.write_text(text)
    print(f"Prepared Termux Godot {package_version}-1 with bundled mbedTLS 4")


if __name__ == "__main__":
    main()

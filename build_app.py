#!/usr/bin/env python3
"""Build a portable native macOS application and architecture-labelled archives."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent
NAME = "对话转换器"
MINIMUM_MACOS = "14.0"


def run(*args, **kwargs):
    return subprocess.run([str(value) for value in args], check=True, **kwargs)


def version():
    value = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("VERSION must contain a release version such as 0.4.0.")
    return value


def architecture(requested=None):
    host = platform.machine()
    if host not in ("arm64", "x86_64"):
        raise ValueError(f"Unsupported build architecture: {host}")
    if requested and requested != host:
        raise ValueError("Build each architecture on a matching Mac or GitHub runner; cross-builds are not supported.")
    return host


def replace_with_backup(source, destination):
    """Replace only a generated app, preserving any previous app for recovery."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if destination.exists():
        backup = ROOT / "backups" / (datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + "-" + destination.name)
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(destination, backup)
        print("Saved previous application:", backup)
    try:
        shutil.copytree(source, destination, symlinks=True)
    except BaseException:
        # Only this incomplete generated copy is removed during rollback.
        if destination.exists():
            shutil.rmtree(destination)
        if backup is not None:
            shutil.move(backup, destination)
        raise
    return destination


def runtime_info(python, arch):
    if not python.is_file():
        raise ValueError("Build runtime is missing. Run: python3 packaging/bootstrap_python.py")
    code = (
        "import importlib.metadata as m,json,pathlib,platform,sysconfig;"
        "d=m.distribution('pyinstaller');"
        "print(json.dumps({'arch':platform.machine(),"
        "'python_license':str(pathlib.Path(sysconfig.get_path('stdlib'))/'LICENSE.txt'),"
        "'pyinstaller_license':str(d.locate_file('pyinstaller-'+d.version+'.dist-info/licenses/COPYING.txt'))}))"
    )
    result = run(python, "-c", code, capture_output=True, text=True)
    info = json.loads(result.stdout)
    if info["arch"] != arch:
        raise ValueError("The Python runtime and native app must have the same architecture.")
    for key in ("python_license", "pyinstaller_license"):
        if not Path(info[key]).is_file():
            raise ValueError(f"Runtime license is missing: {key}")
    return info


def sign_app(app, identity):
    options = ["--options", "runtime", "--timestamp"] if identity != "-" else []
    run("/usr/bin/codesign", "--force", "--sign", identity, *options, app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def make_zip(app, destination):
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, destination)


def notarize(path):
    values = [os.environ.get(name) for name in ("APPLE_ID", "APPLE_APP_PASSWORD", "APPLE_TEAM_ID")]
    if not all(values):
        raise ValueError("Notarization requires APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID.")
    try:
        run("/usr/bin/xcrun", "notarytool", "submit", path, "--apple-id", values[0], "--password", values[1], "--team-id", values[2], "--wait")
    except subprocess.CalledProcessError as error:
        # Do not include the credential-bearing command in an error message.
        raise ValueError(f"Apple notarization failed (exit {error.returncode}); review the notarytool output.") from None


def package_app(app, arch, notarized=False):
    stem = f"DialogueConverter-{version()}-macos-{arch}"
    dist = ROOT / "dist"
    zip_path, dmg_path = dist / (stem + ".zip"), dist / (stem + ".dmg")
    with tempfile.TemporaryDirectory(prefix="converter-package-", dir=ROOT / "build") as workspace:
        staging = Path(workspace)
        temporary_zip = staging / zip_path.name
        make_zip(app, temporary_zip)
        if notarized:
            notarize(temporary_zip)
            run("/usr/bin/xcrun", "stapler", "staple", app)
            run("/usr/bin/xcrun", "stapler", "validate", app)
            temporary_zip.unlink()
            make_zip(app, temporary_zip)
        image_root = staging / "image"
        image_root.mkdir()
        shutil.copytree(app, image_root / app.name, symlinks=True)
        (image_root / "Applications").symlink_to("/Applications", target_is_directory=True)
        (image_root / "安装说明.txt").write_text(
            "将 对话转换器.app 拖到 Applications，然后从应用程序中启动。\n"
            + ("本包已通过 Apple 公证。\n" if notarized else
               "本包使用临时签名，未通过 Apple 公证。首次被阻止时，请在系统设置 → 隐私与安全性中选择“仍要打开”。\n")
            + "macOS 14+；内置运行环境，不需要 Python、Homebrew 或 Xcode。\n",
            encoding="utf-8",
        )
        temporary_dmg = staging / dmg_path.name
        run("/usr/bin/hdiutil", "create", "-volname", NAME, "-srcfolder", image_root, "-format", "UDZO", "-ov", temporary_dmg)
        if notarized:
            notarize(temporary_dmg)
            run("/usr/bin/xcrun", "stapler", "staple", temporary_dmg)
            run("/usr/bin/xcrun", "stapler", "validate", temporary_dmg)
        temporary_zip.replace(zip_path)
        temporary_dmg.replace(dmg_path)
    checksums = []
    for path in (dmg_path, zip_path):
        with path.open("rb") as stream:
            checksums.append(f"{hashlib.file_digest(stream, 'sha256').hexdigest()}  {path.name}\n")
    checksum_path = dist / f"SHA256SUMS-{arch}.txt"
    checksum_path.write_text("".join(checksums), encoding="utf-8")
    print("Release assets:", dmg_path, zip_path, checksum_path, sep="\n")
    return [dmg_path, zip_path, checksum_path]


def build(args):
    if sys.platform != "darwin":
        raise ValueError("The native application must be built on macOS.")
    arch = architecture(args.arch)
    required = ["main.swift", "Models.swift", "MakeIcon.swift", "bridge.py", "README.md", "LICENSE", "VERSION"]
    for name in required:
        if not (ROOT / name).is_file():
            raise FileNotFoundError(ROOT / name)
    identity = os.environ.get("CODESIGN_IDENTITY") or "-"
    if args.notarize and (identity == "-" or not args.package):
        raise ValueError("--notarize requires --package and a Developer ID CODESIGN_IDENTITY.")
    python = Path(args.python).expanduser().resolve() if args.python else ROOT / "build/venv/bin/python"
    info = runtime_info(python, arch)
    build_root = ROOT / "build"
    build_root.mkdir(exist_ok=True)
    environment = os.environ.copy()
    environment["MACOSX_DEPLOYMENT_TARGET"] = MINIMUM_MACOS
    environment["PYINSTALLER_CONFIG_DIR"] = str(build_root / "pyinstaller-cache")
    with tempfile.TemporaryDirectory(prefix="converter-build-", dir=build_root) as workspace:
        staging = Path(workspace)
        app = staging / (NAME + ".app")
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        # PyInstaller enables the hardened runtime for any explicit identity,
        # even "-". Its default ad hoc mode is required without a Team ID.
        signing = ["--codesign-identity", identity] if identity != "-" else []
        run(python, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--name", "bridge-runner",
            "--distpath", staging / "frozen", "--workpath", build_root / "pyinstaller" / arch,
            "--specpath", build_root, "--target-arch", arch, *signing,
            "--exclude-module", "tkinter", "--optimize", "2", "--strip", ROOT / "bridge.py", env=environment)
        shutil.copytree(staging / "frozen/bridge-runner", resources / "bridge", symlinks=True)
        run("/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-target",
            f"{arch}-apple-macosx{MINIMUM_MACOS}", "-O", "-framework", "AppKit", "-framework", "SwiftUI",
            ROOT / "Models.swift", ROOT / "main.swift", "-o", macos / "DialogueConverter")
        run("/usr/bin/xcrun", "swiftc", ROOT / "MakeIcon.swift", "-o", staging / "make-icon")
        run(staging / "make-icon", staging / "icon.png")
        iconset = staging / "Converter.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                run("/usr/bin/sips", "-z", size * scale, size * scale, staging / "icon.png", "--out",
                    iconset / f"icon_{size}x{size}{suffix}.png", stdout=subprocess.DEVNULL)
        run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources / "Converter.icns")
        for name in ("README.md", "LICENSE", "FORMAT_NOTES.md"):
            shutil.copy2(ROOT / name, resources / name)
        licences = resources / "Licenses"
        licences.mkdir()
        shutil.copy2(info["python_license"], licences / "PYTHON-LICENSE.txt")
        shutil.copy2(info["pyinstaller_license"], licences / "PYINSTALLER-COPYING.txt")
        for path in (ROOT / "packaging/licenses").iterdir():
            if path.is_file():
                shutil.copy2(path, licences / path.name)
        bundle_info = {
            "CFBundleName": NAME, "CFBundleDisplayName": NAME,
            "CFBundleExecutable": "DialogueConverter", "CFBundleIdentifier": "local.anyi.dialogue-converter",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version(), "CFBundleVersion": version(),
            "CFBundleIconFile": "Converter.icns", "CFBundleLocalizations": ["zh-Hans"],
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "NSHighResolutionCapable": True, "LSMinimumSystemVersion": MINIMUM_MACOS, "LSUIElement": False,
            "NSHumanReadableCopyright": "Copyright © 2026 Easesgr. MIT License.",
            "ConverterBridgeRelativePath": "Resources/bridge/bridge-runner",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(bundle_info))
        sign_app(app, identity)
        run(sys.executable, ROOT / "packaging/verify_app.py", app, "--arch", arch)
        destination = replace_with_backup(app, ROOT / "dist" / app.name)
    print("Portable application:", destination)
    if args.package:
        package_app(destination, arch, args.notarize)
    if args.install:
        installed = replace_with_backup(destination, Path.home() / "Applications" / destination.name)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", installed)
        print("Installed application:", installed)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="also copy into ~/Applications, preserving the previous app")
    parser.add_argument("--package", action="store_true", help="create DMG, ZIP and SHA256 files")
    parser.add_argument("--notarize", action="store_true", help="notarize and staple a Developer ID signed package")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), help="must match the native build host")
    parser.add_argument("--python", help="optional PyInstaller build runtime; default: build/venv/bin/python")
    try:
        build(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build failed: {error}\n")


if __name__ == "__main__":
    main()

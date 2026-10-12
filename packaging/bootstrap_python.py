#!/usr/bin/env python3
"""Prepare a pinned official python.org runtime locally without a system install."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "3.14.3"
PACKAGE = f"python-{VERSION}-macos11.pkg"
URL = f"https://www.python.org/ftp/python/{VERSION}/{PACKAGE}"
SHA256 = "50b709f72cb5ed87d5882901923face981dd657569717761832c36db3bf08238"


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def relocate_framework(framework):
    prefix = "/Library/Frameworks/Python.framework/"
    magic = {b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    count = 0
    for binary in framework.rglob("*"):
        if binary.is_symlink() or not binary.is_file():
            continue
        relative = binary.relative_to(framework)
        if "Frameworks" in relative.parts or binary == framework / "Versions/3.14/Python":
            continue  # Optional Tcl/Tk frameworks are not used by this bridge.
        with binary.open("rb") as stream:
            if stream.read(4) not in magic:
                continue
        output = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
        dependencies = {line.strip().split(" (", 1)[0] for line in output.splitlines() if line.startswith("\t")}
        changes = []
        for dependency in sorted(dependencies):
            if dependency.startswith(prefix) and dependency != prefix + relative.as_posix():
                target = framework / dependency.removeprefix(prefix)
                if not target.exists():
                    raise RuntimeError(f"Missing dependency in official runtime: {dependency}")
                changes.extend(["-change", dependency, "@loader_path/" + os.path.relpath(target, binary.parent)])
        if changes:
            subprocess.run(["/usr/bin/install_name_tool", *changes, str(binary)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)
            count += 1
    print(f"Relocated {count} maintainer runtime binaries.")


def main():
    if sys.platform != "darwin":
        raise SystemExit("The macOS runtime must be prepared on macOS.")
    build = ROOT / "build"
    downloads = build / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    package = downloads / PACKAGE
    if not package.exists():
        temporary = package.with_suffix(".downloading")
        try:
            with urllib.request.urlopen(URL, timeout=120) as source, temporary.open("wb") as target:
                shutil.copyfileobj(source, target)
            temporary.replace(package)
        finally:
            temporary.unlink(missing_ok=True)
    with package.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != SHA256:
            raise SystemExit("Official Python installer checksum mismatch; remove the downloaded file and retry.")
    framework = build / "python/Python.framework"
    expected = framework / "Versions/3.14/bin/python3.14"
    marker = framework.parent / "python-package.sha256"
    if not expected.is_file() or not marker.is_file() or marker.read_text().strip() != SHA256:
        if framework.exists():
            raise SystemExit(f"Unexpected partial runtime at {framework}; inspect/remove that build artifact before retrying.")
        with tempfile.TemporaryDirectory(prefix="python-extract-", dir=build) as temporary:
            expanded = Path(temporary) / "package"
            run("/usr/sbin/pkgutil", "--expand-full", package, expanded)
            payload = expanded / "Python_Framework.pkg/Payload"
            framework.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(payload, framework, symlinks=True)
        marker.write_text(SHA256 + "\n")
    # Relocate only our extracted build runtime; the system installation stays
    # untouched. PyInstaller separately relocates its final collected runtime.
    relocate_framework(framework)
    venv = build / "venv"
    if not (venv / "bin/python").is_file():
        run(expected, "-m", "venv", venv)
    run(venv / "bin/python", "-m", "pip", "install", "--index-url", "https://pypi.org/simple", "-r", ROOT / "requirements-build.txt")
    print("Maintainer runtime ready:", venv / "bin/python")
    print("Build with: python3 build_app.py --package")


if __name__ == "__main__":
    main()

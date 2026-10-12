#!/usr/bin/env python3
"""Verify a relocated macOS bundle, dependencies and native format conversion."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

MACHO_MAGICS = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def output(*arguments):
    return subprocess.check_output([str(a) for a in arguments], text=True, stderr=subprocess.STDOUT)


def macos_version(value):
    parts = tuple(int(n) for n in value.split("."))
    return parts + (0,) * (3 - len(parts))


def verify_binaries(app, arch, minimum="14.0"):
    binaries, seen = [], set()
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        resolved = path.resolve()
        if resolved in seen:
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                continue
        seen.add(resolved); binaries.append(path)
        if arch not in output("/usr/bin/lipo", "-archs", path).split():
            raise ValueError(f"Architecture mismatch: {path.relative_to(app)}")
        dependencies = output("/usr/bin/otool", "-L", path)
        for line in dependencies.splitlines()[1:]:
            if not line.startswith("\t"):
                continue
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise ValueError(f"External dependency: {path.relative_to(app)} -> {dependency}")
        load_commands = output("/usr/bin/otool", "-l", path)
        targets = re.findall(r"\bminos\s+([\d.]+)", load_commands)
        targets += re.findall(r"LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+([\d.]+)", load_commands)
        if any(macos_version(v) > macos_version(minimum) for v in targets):
            raise ValueError(f"Requires a newer macOS than {minimum}: {path.relative_to(app)}")
    if not binaries:
        raise ValueError("No native executables found.")
    return len(binaries)


def write_records(path, records, append=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a" if append else "w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")


def fingerprint(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(app, arch):
    app = Path(app).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    relative = info.get("ConverterBridgeRelativePath", "")
    if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise ValueError("Invalid bundled helper path.")
    if "ConverterPythonPath" in info:
        raise ValueError("The app still depends on an external Python path.")
    for path in (app / "Contents/MacOS" / info["CFBundleExecutable"], app / "Contents" / relative):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"Missing executable: {path}")
    output("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    binary_count = verify_binaries(app, arch, info["LSMinimumSystemVersion"])
    with tempfile.TemporaryDirectory(prefix="converter-standalone-") as temporary:
        root = Path(temporary)
        relocated = root / "Relocated app with spaces" / app.name
        relocated.parent.mkdir()
        shutil.copytree(app, relocated, symlinks=True)
        output("/usr/bin/codesign", "--verify", "--deep", "--strict", relocated)
        home = root / "Empty home with spaces"
        home.mkdir()
        helper = relocated / "Contents" / relative
        environment = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                       "PYTHONHOME": "/nonexistent", "PYTHONPATH": "/nonexistent"}
        timings = []

        def request(payload, expected_ok=True):
            started = time.monotonic()
            result = subprocess.run([str(helper)], input=json.dumps(payload), text=True, capture_output=True,
                                    env=environment, cwd=root, timeout=30)
            timings.append(time.monotonic() - started)
            if not result.stdout:
                raise RuntimeError(f"Bundled helper returned no JSON (exit {result.returncode}): {result.stderr}")
            response = json.loads(result.stdout)
            if response["ok"] != expected_ok or result.returncode != (0 if expected_ok else 1):
                raise AssertionError(f"Bundled helper failed: {response}; {result.stderr}")
            if result.stderr:
                raise AssertionError(f"Unexpected helper error output: {result.stderr}")
            return response

        empty = request({"action": "list"})
        assert not empty["sessions"], "Isolated helper read real user sessions"
        c = home / ".claude/projects/sample/c.jsonl"
        g = home / ".codex/sessions/sample/g.jsonl"
        write_records(c, [
            {"type": "user", "sessionId": "c-example", "cwd": "/sample", "message": {"role": "user", "content": "保留原始要求"}},
            {"type": "assistant", "sessionId": "c-example", "message": {"role": "assistant", "content": "执行计划", "stop_reason": "end_turn"}},
        ])
        write_records(g, [{"type": "session_meta", "payload": {"id": "g-example", "cwd": "/sample"}},
                          {"type": "response_item", "payload": {"type": "message", "role": "user", "content": "目标已有要求"}}])
        before = (fingerprint(c), fingerprint(g))
        sessions = request({"action": "list"})["sessions"]
        assert {s["id"] for s in sessions} == {"c-example", "g-example"}
        payload = {"action": "prepare", "source_path": str(c), "target_path": str(g), "target_provider": "gpt", "intent": "implement"}
        prepared = request(payload)
        assert prepared["new_message_count"] == 2
        request({"action": "mark", "packet_id": prepared["packet_id"]})
        assert request(payload)["new_message_count"] == 0
        assert before == (fingerprint(c), fingerprint(g)), "Original transcripts were modified"
        write_records(g, [
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": prepared["preview"]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "content": "实施结果：验证通过"}},
            {"type": "event_msg", "payload": {"type": "task_complete"}},
        ], append=True)
        assert request({"action": "probe", "source_path": str(g)})["source_complete"]
        reverse = request({"action": "prepare", "source_path": str(g), "target_path": str(c), "target_provider": "claude", "intent": "review"})
        assert "实施结果：验证通过" in reverse["full_text"]
        assert prepared["preview"] not in reverse["full_text"], "Transport echo was retained on return"
        reopened = request({"action": "read_packet", "packet_id": prepared["packet_id"]})
        assert reopened["full_text"] == prepared["full_text"] and reopened["marked"]
        assert len(request({"action": "history"})["history"]) == 3
        native = request({"action": "native_prepare", "source_path": str(g), "target_provider": "claude", "project": str(root)})["conversion"]
        assert native["state"] == "exported"
        import zipfile
        with zipfile.ZipFile(native["artifact_path"]) as archive:
            manifest = json.loads(archive.read("claude-3p-export.json"))
            assert manifest["counts"] == {"cowork": 1, "code": 0, "chat": 0}
            transcript, = [name for name in archive.namelist() if name.endswith(".jsonl")]
            assert "实施结果：验证通过" in archive.read(transcript).decode()
        assert request({"action": "native_preview", "source_path": str(g)})["message_count"] > 0
        assert len(request({"action": "native_history"})["conversions"]) == 1
        request({"action": "unknown"}, expected_ok=False)
    return {"version": info["CFBundleShortVersionString"], "arch": arch, "verified_native_binaries": binary_count,
            "relocated_minimal_path": True, "native_cowork_export": True,
            "average_helper_seconds": round(sum(timings) / len(timings), 3)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.app, arguments.arch), ensure_ascii=False, indent=2))

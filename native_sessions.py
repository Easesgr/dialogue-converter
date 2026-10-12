"""Native session formats. No model calls or writes to existing histories."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile

import bridge


def uuid_string(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def cowork_roots(app):
    if app.cowork:
        root = app.cowork.expanduser().resolve()
        return [root if root.name == "local-agent-mode-sessions" else root / "local-agent-mode-sessions"]
    if not app.autodiscover_cowork:
        return []
    support = Path.home() / "Library/Application Support"
    return [support / name / "local-agent-mode-sessions" for name in ("Claude-3p", "Claude")]


def cowork_metadata(path):
    path = bridge.normalized_path(path)
    if not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Cowork 会话信息文件无效或过大。")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("Cowork 会话信息必须是 JSON 对象。")
    sid = value.get("sessionId", "")
    cli = value.get("cliSessionId", "")
    if not isinstance(sid, str) or not sid.startswith("local_") or not uuid_string(sid[6:]) or not uuid_string(cli):
        raise ValueError("Cowork 会话缺少有效的本机与引擎会话编号。")
    if value.get("sessionType") == "chat":
        raise ValueError("这是 Claude Chat 会话，请选择 Cowork 协作任务。")
    for name in (sid, sid[6:], sid[6:14]):
        root = path.parent / name
        for candidate in (root / ".claude/projects").glob("*/" + cli + ".jsonl"):
            resolved = candidate.resolve()
            if resolved.is_relative_to(path.parent) and candidate.is_file():
                return path, value, resolved
    raise ValueError("未找到此 Cowork 任务的引擎记录；它可能尚未下载到本机。")


def read_cowork(path, probe=False):
    metadata_path, metadata, transcript_path = cowork_metadata(path)
    doc = bridge.read_transcript(transcript_path, "claude", probe=probe)
    if not probe:
        # Resolve the active UUID chain; exclude abandoned retries and sidechains.
        records = []
        snapshot = transcript_path.stat()
        size = snapshot.st_size
        if (size, snapshot.st_mtime_ns) != (doc.size, doc.modified_ns):
            raise ValueError("来源任务仍在写入；请在完成后刷新再转换。")
        with transcript_path.open("rb") as stream:
            remaining = size
            while remaining:
                line = stream.readline(remaining)
                if not line:
                    break
                remaining -= len(line)
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError):
                    raise ValueError("来源记录正在写入或已损坏；请等待任务完成后重试。") from None
                if isinstance(record, dict):
                    records.append(record)
        nodes = {r["uuid"]: r for r in records if isinstance(r.get("uuid"), str)}
        leaves = [r for r in records if r.get("type") in ("user", "assistant")
                  and r.get("uuid") and not r.get("isSidechain")]
        if leaves and "parentUuid" in leaves[-1]:
            chain, seen = [], set()
            current = leaves[-1]["uuid"]
            while current:
                if current in seen or current not in nodes:
                    raise ValueError("Cowork 消息链不完整；已停止转换，避免导入错误历史。")
                seen.add(current)
                node = nodes[current]
                chain.append(node)
                current = (node.get("logicalParentUuid") if node.get("subtype") == "compact_boundary"
                           else node.get("parentUuid"))
            doc.messages.clear()
            doc._identities.clear()
            doc._origins.clear()
            doc._last_origin = ""
            for record in reversed(chain):
                bridge.consume(record, doc)
        current_stat = transcript_path.stat()
        if (current_stat.st_size, current_stat.st_mtime_ns) != (size, snapshot.st_mtime_ns):
            raise ValueError("来源任务仍在写入；请在完成后刷新再转换。")
    doc.native_id = metadata["sessionId"]
    doc.title = metadata.get("title") or "Cowork 协作任务"
    doc.path = str(metadata_path)
    doc.surface = "cowork"
    doc.modified_ns = max(metadata_path.stat().st_mtime_ns, transcript_path.stat().st_mtime_ns)
    doc.cwd = ""  # Cowork's engine output folder is not a shared project.
    if not doc.messages:
        raise ValueError("此 Cowork 任务没有可转换的可见文字消息。")
    return doc


def discover_cowork(app):
    sessions, warnings, paths = [], [], []
    for root in cowork_roots(app):
        if root.exists():
            paths.extend(root.glob("*/*/local_*.json"))
    dated = []
    for path in paths:
        try:
            dated.append((path.stat().st_mtime_ns, path))
        except OSError:
            warnings.append("一个 Cowork 任务未能读取；请确认任务已保存到本机。")
    dated.sort(key=lambda item: item[0], reverse=True)
    for _, path in dated[:200]:
        try:
            sessions.append(read_cowork(path, probe=True).session())
        except (ValueError, OSError, UnicodeError):
            warnings.append("一个 Cowork 任务未能读取；请确认任务已保存到本机。")
    return sessions, list(dict.fromkeys(warnings))


def native_messages(doc):
    messages = [{"role": m["role"], "content": m["content"]} for m in doc.messages
                if m["role"] in ("user", "assistant")
                and not (doc.provider == "gpt" and m["role"] == "assistant"
                         and m["content"] == "<EXTERNAL SESSION IMPORTED>")]
    if not messages or not any(m["role"] == "user" for m in messages):
        raise ValueError("原生转换需要包含用户与助手角色的会话记录。")
    return messages


def claude_records(messages, session_id, cwd, title=""):
    parent = None
    timestamp = datetime.now(timezone.utc) - timedelta(milliseconds=len(messages))
    records = []
    if title:
        records.append({"type": "custom-title", "sessionId": session_id, "customTitle": title})
    for index, message in enumerate(messages):
        identifier = str(uuid.uuid4())
        role = message["role"]
        body = {"role": role, "content": [{"type": "text", "text": message["content"]}]}
        if role == "assistant":
            body.update({"id": "msg_" + uuid.uuid4().hex, "type": "message", "stop_reason": "end_turn"})
        records.append({"type": role, "uuid": identifier, "parentUuid": parent,
                        "sessionId": session_id, "cwd": cwd, "isSidechain": False,
                        "timestamp": (timestamp + timedelta(milliseconds=index)).isoformat().replace("+00:00", "Z"),
                        "message": body})
        parent = identifier
    return records


def jsonl(records):
    return "".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records)


def write_cowork_bundle(path, messages, title, source_id, cli_id):
    account, org = str(uuid.uuid4()), str(uuid.uuid4())
    root = f"local-agent-mode-sessions/{account}/{org}"
    native_id = "local_" + source_id
    timestamp = int(time.time() * 1000)
    manifest = {"kind": "claude-desktop-export", "version": 1,
                "exportedAt": bridge.now(), "counts": {"cowork": 1, "code": 0, "chat": 0}}
    metadata = {"sessionId": native_id, "cliSessionId": cli_id, "title": title,
                "createdAt": timestamp, "lastActivityAt": timestamp, "isArchived": False}
    records = claude_records(messages, cli_id, "/sessions/dialogue-converter", title)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".bundle-", dir=path.parent)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, value in (("claude-3p-export.json", json.dumps(manifest)),
                                (f"{root}/{native_id}.json", json.dumps(metadata, ensure_ascii=False)),
                                (f"{root}/{native_id}/.claude/projects/session/{cli_id}.jsonl", jsonl(records))):
                info = zipfile.ZipInfo(name)
                info.external_attr = 0o100600 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, value)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def find_codex(explicit=None):
    if explicit:
        candidate = bridge.normalized_path(explicit)
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise ValueError("配置的 Codex 程序不可执行，请重新选择 Codex.app。")
        return candidate
    for directory in (Path("/Applications"), Path.home() / "Applications"):
        for app in ("Codex.app", "ChatGPT.app"):
            candidate = directory / app / "Contents/Resources/codex-cli/bin/codex"
            if candidate.is_file():
                return candidate
    raise ValueError("未找到 Codex 桌面端内置程序，请在应用连接中选择 Codex.app。")


class AppServer:
    """Bounded JSON RPC transport, including buffered lines and server requests."""
    def __init__(self, binary, codex_home, staging_home):
        codex_home.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.events = queue.Queue()
        self.pending = []
        self.identifier = 0
        self.deadline = time.monotonic() + 65
        environment = os.environ.copy()
        environment["CODEX_HOME"] = str(codex_home)
        environment["HOME"] = str(staging_home)
        environment.pop("CLAUDE_CONFIG_DIR", None)
        self.process = subprocess.Popen([str(binary), "app-server", "--stdio"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=environment, text=True,
                                        encoding="utf-8", bufsize=1, cwd=staging_home)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.process.stdout:
                try:
                    self.events.put(json.loads(line))
                except ValueError:
                    self.events.put({"transport_error": True})
        finally:
            self.events.put(None)

    def send(self, method, params, identifier=None):
        value = {"method": method, "params": params}
        if identifier is not None:
            value["id"] = identifier
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def wait(self, predicate, timeout=55):
        for index, value in enumerate(self.pending):
            if predicate(value):
                return self.pending.pop(index)
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            try:
                value = self.events.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            if value is None or value.get("transport_error"):
                raise ValueError("Codex 导入服务提前退出或返回无效数据。")
            if "method" in value and "id" in value:
                self.process.stdin.write(json.dumps({"id": value["id"], "error": {
                    "code": -32601, "message": "Converter does not execute tools"}}) + "\n")
                self.process.stdin.flush()
                continue
            if predicate(value):
                return value
            self.pending.append(value)
        raise ValueError("Codex 导入服务等待超时。请查看转换记录，勿重复创建会话。")

    def call(self, method, params):
        self.identifier += 1
        identifier = self.identifier
        self.send(method, params, identifier)
        response = self.wait(lambda value: value.get("id") == identifier)
        if "error" in response:
            message = response["error"].get("message", "未知协议错误")
            raise ValueError("Codex 原生接口拒绝请求：" + str(message)[:600])
        return response["result"]

    def __enter__(self):
        self.call("initialize", {"clientInfo": {"name": "dialogue_converter", "version": "0.4.0"},
                                 "capabilities": {"experimentalApi": True}})
        self.send("initialized", {})
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=1)
        self.process.stdout.close()


def thread_messages(thread):
    actual = []
    for turn in thread["turns"]:
        for item in turn["items"]:
            if item["type"] == "userMessage":
                actual.append({"role": "user", "content": bridge.visible_text(item["content"])})
            elif item["type"] == "agentMessage" and item["text"] != "<EXTERNAL SESSION IMPORTED>":
                actual.append({"role": "assistant", "content": item["text"]})
    return actual


def import_codex(binary, codex_home, staged, title, cwd, on_target=None):
    staging_home = staged.parents[3]
    server = AppServer(binary, codex_home, staging_home)
    try:
        with server:
            accepted = server.call("externalAgentConfig/import", {"migrationItems": [{
                "itemType": "SESSIONS", "description": "Dialogue Converter native history",
                "details": {"sessions": [{"path": str(staged), "cwd": cwd, "title": title}]}}],
                "source": "dialogue_converter"})
            completed = server.wait(lambda value: value.get("method") == "externalAgentConfig/import/completed"
                                    and value.get("params", {}).get("importId") == accepted["importId"])
            results = completed["params"]["itemTypeResults"]
            failures = [failure for result in results for failure in result["failures"]]
            successes = [success for result in results for success in result["successes"]
                         if success.get("itemType") == "SESSIONS" and success.get("target")]
            if failures or len(successes) != 1:
                detail = failures[0].get("message", "") if failures else "没有返回唯一的目标会话。"
                raise ValueError("Codex 未完成导入：" + detail[:600])
            target = successes[0]["target"]
            if not uuid_string(target):
                raise ValueError("Codex 返回的目标会话编号无效。")
            if on_target is not None:
                on_target(target)
            thread = server.call("thread/read", {"threadId": target, "includeTurns": True})["thread"]
            expected = native_messages(bridge.read_transcript(staged))
            if thread_messages(thread) != expected:
                raise ValueError("Codex 已创建会话，但读回的角色、顺序或文字与原文不同，请检查目标会话。")
            return thread
    finally:
        server.close()


def receipt_path(app, identifier):
    if not uuid_string(identifier):
        raise ValueError("转换记录编号无效。")
    return app.root / "conversions" / identifier / "receipt.json"


def receipt(app, identifier):
    value = json.loads(receipt_path(app, identifier).read_text(encoding="utf-8"))
    if value.get("id") != identifier or value.get("version") != 1:
        raise ValueError("转换记录版本或编号不匹配。")
    return value


def preview(app, request):
    doc = app.load_document(bridge.required_string(request, "source_path"))
    if doc.provider not in bridge.PROVIDERS or not doc.native_id:
        raise ValueError("请选择带有原生会话编号的 Cowork 或 Codex 记录。")
    messages = native_messages(doc)
    text = bridge.render_messages(list(enumerate(messages)))
    if len(text) > 32000:
        text = text[:16000] + "\n\n…预览省略中间部分；原生转换保留全部可见文字…\n\n" + text[-16000:]
    return {"source": doc.session(), "message_count": len(messages), "preview": text,
            "characters": sum(len(m["content"]) for m in messages), "warnings": doc.warnings}


def prepare(app, request):
    doc = app.load_document(bridge.required_string(request, "source_path"))
    if doc.provider not in bridge.PROVIDERS or not doc.native_id:
        raise ValueError("请选择带有原生会话编号的 Cowork 或 Codex 记录。")
    messages = native_messages(doc)
    if doc.warnings:
        raise ValueError("来源记录不完整或仍在写入，请等待完成后刷新。" + " ".join(doc.warnings))
    destination = request.get("target_provider")
    if destination not in bridge.PROVIDERS or destination == doc.provider:
        raise ValueError("请选择另一应用作为转换目标。")
    project = request.get("project", "") or (doc.cwd if doc.provider == "gpt" else "")
    if not isinstance(project, str):
        raise ValueError("项目必须是本机目录路径。")
    if project:
        project = str(bridge.normalized_path(project))
        if not Path(project).is_dir():
            raise ValueError("项目目录不存在，请选择可访问的本机文件夹。")
    if destination == "gpt" and not project:
        raise ValueError("请为 Codex 选择本机项目目录。Cowork 内部工作目录无法直接沿用。")
    fingerprint = bridge.digest(json.dumps([doc.provider, doc.native_id, destination, project, messages],
                                          ensure_ascii=False, sort_keys=True))
    with app.locked():
        for path in (app.root / "conversions").glob("*/receipt.json"):
            previous = json.loads(path.read_text())
            if previous.get("fingerprint") == fingerprint:
                return {"conversion": previous, "warnings": ["这份会话快照已转换，已打开原转换记录。"]}
        identifier, native_id, cli_id = (str(uuid.uuid4()) for _ in range(3))
        root = app.root / "conversions" / identifier
        root.mkdir(parents=True, mode=0o700)
        title = doc.title or doc.session()["title"]
        value = {"version": 1, "id": identifier, "created_at": bridge.now(), "fingerprint": fingerprint,
                 "source": doc.session(), "target_provider": destination, "title": title,
                 "project": project, "message_count": len(messages), "state": "prepared",
                 "native_id": native_id, "cli_id": cli_id}
        bridge.write_json(root / "dialogue.json", {"messages": messages})
        if destination == "claude":
            path = root / "Cowork-conversation.zip"
            write_cowork_bundle(path, messages, title, native_id, cli_id)
            value["artifact_path"] = str(path)
            value["state"] = "exported"
        else:
            staged = root / "staging-home/.claude/projects/dialogue-converter" / (cli_id + ".jsonl")
            bridge.atomic_write(staged, jsonl(claude_records(messages, cli_id, project, title)))
            value["artifact_path"] = str(staged)
        bridge.write_json(receipt_path(app, identifier), value)
    return {"conversion": value, "warnings": ["已转换全部可见文字。工具执行、附件内容、私有推理与文件权限不迁移。"]}


def perform_import(app, request):
    identifier = bridge.required_string(request, "conversion_id")
    binary = find_codex(request.get("codex_binary"))
    with app.locked():
        value = receipt(app, identifier)
        if value["target_provider"] != "gpt":
            raise ValueError("Cowork 原生 ZIP 请通过 Claude 的设置 → 导入与导出导入。")
        if value["state"] == "imported":
            return {"conversion": value, "warnings": []}
        if value["state"] in ("importing", "uncertain"):
            raise ValueError("上次导入未能确认结果。请先在 Codex 查找该会话，避免重复导入。")
        value["state"] = "importing"
        bridge.write_json(receipt_path(app, identifier), value)
        try:
            def remember_target(target):
                value["target_id"] = target
                bridge.write_json(receipt_path(app, identifier), value)
            thread = import_codex(binary, app.codex, Path(value["artifact_path"]), value["title"], value["project"],
                                  on_target=remember_target)
            value.update({"state": "imported", "target_id": thread["id"], "target_path": thread.get("path"),
                          "completed_at": bridge.now()})
        except (OSError, ValueError, KeyError) as error:
            value.update({"state": "uncertain", "error": str(error)})
            bridge.write_json(receipt_path(app, identifier), value)
            raise
        bridge.write_json(receipt_path(app, identifier), value)
    return {"conversion": value, "warnings": []}


def verify_codex(app, request):
    identifier = bridge.required_string(request, "conversion_id")
    binary = find_codex(request.get("codex_binary"))
    with app.locked():
        value = receipt(app, identifier)
        target = value.get("target_id")
        if value["target_provider"] != "gpt" or not uuid_string(target):
            raise ValueError("尚未取得 Codex 目标编号，请先在 Codex 查找会话，避免重复导入。")
        server = AppServer(binary, app.codex, Path(value["artifact_path"]).parents[3])
        try:
            with server:
                thread = server.call("thread/read", {"threadId": target, "includeTurns": True})["thread"]
        finally:
            server.close()
        expected = json.loads((receipt_path(app, identifier).parent / "dialogue.json").read_text())["messages"]
        if thread_messages(thread)[:len(expected)] != expected:
            raise ValueError("Codex 目标会话的角色、顺序或文字与转换原文不同，请检查目标会话。")
        value.update({"state": "imported", "target_path": thread.get("path"), "completed_at": bridge.now()})
        value.pop("error", None)
        bridge.write_json(receipt_path(app, identifier), value)
    return {"conversion": value, "warnings": []}


def verify_cowork(app, request):
    identifier = bridge.required_string(request, "conversion_id")
    with app.locked():
        value = receipt(app, identifier)
        if value["target_provider"] != "claude":
            raise ValueError("此记录的目标不是 Cowork。")
        expected = json.loads((receipt_path(app, identifier).parent / "dialogue.json").read_text())["messages"]
        warnings = []
        for root in cowork_roots(app):
            for path in root.glob("*/*/local_*.json"):
                try:
                    metadata = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, ValueError, UnicodeError):
                    warnings.append("部分 Cowork 记录暂时无法读取，请等待保存完成后刷新。")
                    continue
                if not isinstance(metadata, dict):
                    warnings.append("部分 Cowork 记录格式无效，未用于导入核对。")
                    continue
                if metadata.get("cliSessionId") != value["cli_id"]:
                    continue
                imported = read_cowork(path)
                actual = native_messages(imported)
                if actual[:len(expected)] != expected:
                    raise ValueError("Cowork 已出现目标会话，但读回的消息与转换原文不同。")
                value.update({"state": "imported", "target_id": imported.native_id,
                              "target_path": str(path), "completed_at": bridge.now()})
                bridge.write_json(receipt_path(app, identifier), value)
                return {"conversion": value, "warnings": list(dict.fromkeys(warnings))}
    return {"conversion": value, "warnings": list(dict.fromkeys(warnings)) + [
        "尚未在当前 Cowork 资料目录检测到此会话。如果 Claude 已显示历史，请在应用连接中选择对应资料目录后重试。"]}


def dispatch(app, request):
    action = request.get("action")
    if action == "native_preview":
        return preview(app, request)
    if action == "native_prepare":
        return prepare(app, request)
    if action == "native_import":
        return perform_import(app, request)
    if action == "native_verify":
        with app.locked():
            destination = receipt(app, bridge.required_string(request, "conversion_id"))["target_provider"]
        return verify_cowork(app, request) if destination == "claude" else verify_codex(app, request)
    if action == "native_history":
        with app.locked():
            entries = [json.loads(p.read_text()) for p in (app.root / "conversions").glob("*/receipt.json")]
        entries.sort(key=lambda value: value["created_at"], reverse=True)
        return {"conversions": entries[:100]}
    if action == "native_read":
        with app.locked():
            return {"conversion": receipt(app, bridge.required_string(request, "conversion_id"))}
    raise ValueError("未知原生转换操作。")

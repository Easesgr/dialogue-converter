# 对话转换器 · Dialogue Converter

**把 Claude 的计划交给 Codex 实施，再把结果交回 Claude 审查。**

原生 macOS 应用。转换和交接在这里完成，对话与模型调用继续留在各自的应用中。

[下载安装](https://github.com/Easesgr/dialogue-converter/releases/latest) · [English](#english) · [构建](docs/BUILD.md) · [隐私](docs/PRIVACY.md) · [MIT License](LICENSE)

![对话转换器原生窗口，使用隔离的笔记搜索示例](docs/images/demo.png)

## 安装

需要 **macOS 14 或更新版本**。安装包内置转换运行环境，无需安装 Python、Homebrew 或 Xcode。

| 你的 Mac | 下载 |
| --- | --- |
| Apple Silicon（M 系列） | [arm64 DMG](https://github.com/Easesgr/dialogue-converter/releases/latest/download/DialogueConverter-0.3.0-macos-arm64.dmg) |
| Intel | [x86_64 DMG](https://github.com/Easesgr/dialogue-converter/releases/latest/download/DialogueConverter-0.3.0-macos-x86_64.dmg) |

打开 DMG，将 **对话转换器.app** 拖到 **Applications**，然后从应用程序启动。Release 页面也提供 ZIP 和 SHA256 校验文件。

当前公开包使用临时签名，**没有经过 Apple 公证**。首次打开如果被 macOS 阻止，请在尝试打开后进入 **系统设置 → 隐私与安全性 → 仍要打开**，核对应用名称并确认。部分系统也支持在 Finder 中右键应用选择“打开”。无需关闭系统安全保护。受管理的 Mac 可能需要管理员批准。

## 使用

1. 选择来源：本机 Claude Code / Codex 对话，或粘贴、导入已完成的计划。
2. 选择去向和交接目的：实施、审查或继续任务。已有本机会话可以绑定到具体目标。
3. 点击 **转换交接内容**，检查预览。
4. 点击 **复制并打开目标应用**，在原应用中选择目标对话，按 ⌘V 粘贴并发送。
5. 发送后回到转换器，点击 **已在原应用发送**。完成后 **交换两边**，交回新增结果。

转换器会激活目标应用；选中哪段对话、发送哪条消息仍由你在原应用中决定。Claude Code 终端会话可使用“仅复制”，然后切回终端。

### 支持的来源

| 来源 | 导入方式 |
| --- | --- |
| Claude Code | 读取 `~/.claude/projects` 中的原生 JSONL |
| Codex CLI / Codex 应用 | 读取 `~/.codex/sessions` 与 `archived_sessions` 中的原生 JSONL |
| Claude Desktop / Web / Cowork | 复制可见文字，或导入可读取的导出文件 |
| ChatGPT / 其他工具 | 粘贴文字、Markdown 或包含 `role` / `content` 消息的 JSON |

原应用的记录格式可能随版本改变。没有出现在列表中的对话可以手动导入；图片、音频、二进制附件、工具输出和私有推理不转换。

## 实用功能

- **双向交接与增量进度**：绑定明确的来源和目标会话后，已确认发送的内容不会再次交接。复制、导出和打开应用不会推进进度。
- **交接历史**：重新打开最近 100 条交接包，继续复制、导出或确认发送；全部文件仍在本机资料目录。
- **简洁交接 / 完整原文**：简洁版本控制预览长度，必要时引用完整本机文件；无法读取本机文件的应用可使用完整原文或附加导出文件。
- **应用连接设置**：自动发现 Claude / Codex，也可以指定其他 `.app`；会话数据目录可自定义。
- **完成后跟随**：每 3 秒检查来源文件是否变化，有明确完成记录时准备交接；可选复制并切换应用，发送仍需在原应用确认。
- **会话筛选、项目选择、原文导出**：搜索标题或项目，保留项目目录、可见要求和结果。
- **历史变化检测**：源文件被改写或截断时重新交接完整可见参考，旧交接包不能推进新进度。
- **原生快捷键**：⌘Return 转换，⌘⇧Return 复制并打开，⌘⇧X 交换，⌘⇧H 历史，⌘⇧V 从剪贴板导入。

### 增量交接的边界

选择“新建 / 手动选择”时，转换器不知道你最终发送到了哪段原生对话，每次转换都会创建独立的目标范围。后续请选择明确的目标本机会话，才能持续记录该会话的增量进度。粘贴内容改变后会视为新的导入，避免把无关内容套用到旧进度上。

简洁交接不是模型生成的摘要。全部本次可见原文保存在本机交接文件中；若目标无法访问文件，请复制完整原文或附加文件。

## 隐私与性能

转换模块只处理本机文件，不联网、不调用模型。源会话文件保持只读。交接文件和进度保存在：

```text
~/Library/Application Support/DialogueConverter/
```

本机目录权限为 `0700`，文件为 `0600`。偏好设置保存应用路径和已选会话，不保存 API Key。详细说明见 [PRIVACY.md](docs/PRIVACY.md)。

应用不修改 Claude / Codex 的模型、推理强度、额度、缓存或压缩设置。交接增加的参考仍会占用接收方上下文和模型用量；不同模型的私有状态、工具运行状态和效果无法完整迁移。大文件的列表和完成探测只读首尾；实际转换会读取完整可见内容。

## 开发

```bash
python3 -m unittest discover -s tests -v
python3 packaging/bootstrap_python.py
python3 build_app.py --package
```

详见 [BUILD.md](docs/BUILD.md) 和 [RELEASE.md](docs/RELEASE.md)。欢迎附上经过脱敏的最小格式示例提交问题或 PR；请勿提交真实对话、访问令牌和个人资料目录。

## English

Dialogue Converter is a **native macOS handoff utility** for Claude and Codex / GPT. Plan in Claude, implement in Codex, and bring the result back for review. Conversations and model execution stay in their original apps.

- Download the matching Apple Silicon or Intel build from [Releases](https://github.com/Easesgr/dialogue-converter/releases/latest). macOS 14+; the runtime is bundled.
- Select a local Claude Code / Codex transcript, or paste/import visible text. Choose the destination and handoff purpose, convert, review, then copy and open the destination app.
- Paste and send in the original app. Return to the converter and explicitly acknowledge sending. Bound native conversation pairs support incremental handoffs in both directions.
- Reopen handoff history, export the complete text, configure app/data paths, or follow explicit completion records.
- Claude Desktop/Web/Cowork and ChatGPT conversations use copy/import. Private reasoning, tool output, images and binary attachments are excluded.
- Conversion runs locally and makes no model calls. It does not change either app's settings. Imported references consume destination context; identical model behavior cannot be guaranteed.

The interface is currently in Chinese. Public builds are ad hoc signed and **not notarized**: after an initial blocked launch, use macOS **System Settings → Privacy & Security → Open Anyway**. Managed Macs may require an administrator. Developer ID signing and notarization are supported by the release tooling when maintainer credentials are available.

MIT licensed. Python and bundled runtime components retain their own licenses.

# 对话转换器 0.3.0

原生 macOS 应用：在 Claude 与 Codex / GPT 之间转换交接资料，对话继续在原应用进行。

## 本版功能

- 双向转换、明确目标会话的增量交接、发送后的手动确认。
- 交接历史、重新复制、完整原文复制和 Markdown 导出。
- 应用及数据目录配置、会话筛选、项目选择和快捷键。
- 来源完成后准备交接，可选复制并切换应用。
- 内置转换运行环境，无需 Python / Homebrew / Xcode。

## 下载与安装

macOS 14+。M 系列 Mac 选择 `arm64`，Intel Mac 选择 `x86_64`。

打开 DMG，将“对话转换器.app”拖到 Applications。也可下载 ZIP。

**本版公开包使用临时签名，未通过 Apple 公证。** 首次被 macOS 阻止时，尝试打开后进入“系统设置 → 隐私与安全性 → 仍要打开”。无需关闭系统安全保护。受管理的 Mac 可能需要管理员批准。

Claude Code 与 Codex 的本机 JSONL 会话可以直接读取；Claude Desktop / Web / Cowork 与 ChatGPT 对话使用复制或导入。转换器会激活目标应用，目标对话的选择和发送仍需在原应用完成。私有推理、工具输出和二进制附件不转换。

Conversion is local and makes no model calls. Chats stay in their original applications. macOS 14+, Apple Silicon and Intel; Chinese interface. Public assets are ad hoc signed and not notarized. Review the README for supported formats and context limits.

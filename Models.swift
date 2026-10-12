import AppKit
import Foundation
import SwiftUI

enum Provider: String, CaseIterable, Identifiable {
    case claude, gpt
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex / GPT" }
    var other: Provider { self == .claude ? .gpt : .claude }
    var color: Color { self == .claude ? Color(red: 0.66, green: 0.36, blue: 0.24) : Color(red: 0.18, green: 0.40, blue: 0.33) }
    var appPreference: String { self == .claude ? "claudeAppPath" : "codexAppPath" }
    var directoryPreference: String { self == .claude ? "claudeHome" : "codexHome" }
}

struct NativeSession: Decodable, Identifiable {
    let id: String
    let provider: String
    let title: String
    let cwd: String
    let path: String
    let updated_at: String
    let complete: Bool
    let message_count: Int
    var pickerTitle: String { "\(title.prefix(45)) · \(id.prefix(8))" }
}

struct PacketHistory: Decodable, Identifiable {
    let packet_id: String
    let created_at: String
    let source: NativeSession?
    let target: NativeSession?
    let source_provider: String
    let target_provider: String
    let new_message_count: Int
    let valid: Bool
    let marked: Bool
    var id: String { packet_id }
    var title: String { source?.title ?? "粘贴 / 导入的对话" }
    var direction: String { "\(Provider(rawValue: source_provider)?.title ?? source_provider) → \(Provider(rawValue: target_provider)?.title ?? target_provider)" }
    var stateTitle: String { !valid ? "历史已改变" : (marked ? "已确认发送" : "待确认") }
    var dateTitle: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: created_at) else { return created_at }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct BridgeResponse: Decodable {
    let ok: Bool
    let error: String?
    let sessions: [NativeSession]?
    let warnings: [String]?
    let session: NativeSession?
    let source: NativeSession?
    let target: NativeSession?
    let preview: String?
    let full_text: String?
    let text: String?
    let packet_id: String?
    let artifact_path: String?
    let characters: Int?
    let message_count: Int?
    let new_message_count: Int?
    let source_complete: Bool?
    let source_provider: String?
    let target_provider: String?
    let intent: String?
    let project: String?
    let marked: Bool?
    let valid: Bool?
    let history: [PacketHistory]?
    let total: Int?
}

struct ConverterFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class ProcessErrorBuffer {
    private let lock = NSLock()
    private var data = Data()
    func store(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum BridgeClient {
    static func request(_ payload: [String: Any]) async throws -> BridgeResponse {
        let input = try JSONSerialization.data(withJSONObject: payload)
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        guard let relativePath = Bundle.main.object(forInfoDictionaryKey: "ConverterBridgeRelativePath") as? String,
              !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw ConverterFailure(message: "应用的转换模块配置不完整，请重新安装。")
        }
        let helper = contents.appendingPathComponent(relativePath)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConverterFailure(message: "找不到内置转换模块，请重新安装完整的应用。")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = helper
                    var environment = ProcessInfo.processInfo.environment
                    environment["PYTHONIOENCODING"] = "utf-8"
                    environment.removeValue(forKey: "PYTHONHOME")
                    environment.removeValue(forKey: "PYTHONPATH")
                    process.environment = environment
                    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                    let errors = ProcessErrorBuffer()
                    try process.run()
                    let errorRead = DispatchGroup()
                    errorRead.enter()
                    DispatchQueue.global().async {
                        errors.store(stderr.fileHandleForReading.readDataToEndOfFile())
                        errorRead.leave()
                    }
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
                    try stdin.fileHandleForWriting.write(contentsOf: input)
                    try stdin.fileHandleForWriting.close()
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); timeout.cancel(); errorRead.wait()
                    guard !output.isEmpty else {
                        let detail = String(data: errors.read(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        throw ConverterFailure(message: detail.isEmpty ? "转换模块未返回结果（退出码 \(process.terminationStatus)）。" : String(detail.prefix(500)))
                    }
                    let response = try JSONDecoder().decode(BridgeResponse.self, from: output)
                    guard response.ok, process.terminationStatus == 0 else { throw ConverterFailure(message: response.error ?? "转换未完成。") }
                    continuation.resume(returning: response)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
final class ConverterModel: ObservableObject {
    @Published var sessions: [NativeSession] = []
    @Published var sourceProvider: Provider = .claude
    @Published var sourcePath = ""
    @Published var targetPath = ""
    @Published var sourceMode = "session"
    @Published var pastedText = ""
    @Published var projectPath = ""
    @Published var intent = "implement"
    @Published var packet: BridgeResponse?
    @Published var isBusy = false
    @Published var status = "选择来源对话，或导入已经完成的计划。"
    @Published var warning = ""
    @Published var hasCopied = false
    @Published var hasMarked = false
    @Published var copyFullText = false
    @Published var watchSource = false
    @Published var autoSwitch = false
    @Published var showConnections = false
    @Published var showHistory = false
    @Published var history: [PacketHistory] = []
    @Published var historyWarning = ""
    @Published var historyTotal = 0
    let isDemo: Bool
    private let demoDirectory: URL
    private var timer: Timer?
    private var observedStamp: String?
    private var notifiedPacket = ""
    private let preferences = UserDefaults.standard

    init(demo: Bool = false) {
        isDemo = demo
        demoDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dialogue-converter-demo-" + UUID().uuidString)
    }
    var sourceSessions: [NativeSession] { sessions.filter { $0.provider == sourceProvider.rawValue } }
    var targetSessions: [NativeSession] { sessions.filter { $0.provider == sourceProvider.other.rawValue } }
    var selectedSource: NativeSession? { sourceSessions.first { $0.path == sourcePath } }
    var selectedTarget: NativeSession? { targetSessions.first { $0.path == targetPath } }
    var canPrepare: Bool { !isBusy && (sourceMode == "session" ? !sourcePath.isEmpty : !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var canCopy: Bool { packet != nil && !isBusy }
    var canMark: Bool { hasCopied && !hasMarked && !isBusy && packet?.valid != false }
    var targetProvider: Provider { Provider(rawValue: packet?.target_provider ?? "") ?? sourceProvider.other }
    var clipboardText: String? { copyFullText ? packet?.full_text : packet?.preview }

    private func request(_ payload: [String: Any]) async throws -> BridgeResponse {
        var configured = payload
        if isDemo {
            configured["data_dir"] = demoDirectory.appendingPathComponent("state").path
            configured["claude_home"] = demoDirectory.appendingPathComponent("claude").path
            configured["codex_home"] = demoDirectory.appendingPathComponent("codex").path
        } else {
            for provider in Provider.allCases {
                if let path = preferences.string(forKey: provider.directoryPreference), !path.isEmpty {
                    configured[provider == .claude ? "claude_home" : "codex_home"] = path
                }
            }
        }
        return try await BridgeClient.request(configured)
    }
    func start() async {
        if isDemo {
            sourceMode = "paste"
            pastedText = "目标：为笔记应用增加全文搜索。\n要求：保留现有数据格式，支持中文，附上使用说明。\n\nClaude 的计划：\n1. 检查笔记读取和列表展示。\n2. 添加本地搜索与清空入口。\n3. 验证中文关键词、空查询和无结果状态。\n4. 汇总修改和验证结果，交回 Claude 审查。"
            projectPath = "/Projects/Notes"
            await prepare()
            status = "示例模式 · 示例内容和交接记录与真实对话隔离。"
            return
        }
        sourceProvider = Provider(rawValue: preferences.string(forKey: "sourceProvider") ?? "claude") ?? .claude
        sourcePath = preferences.string(forKey: "sourcePath") ?? ""
        targetPath = preferences.string(forKey: "targetPath") ?? ""
        projectPath = preferences.string(forKey: "projectPath") ?? ""
        intent = preferences.string(forKey: "intent") ?? (sourceProvider == .claude ? "implement" : "review")
        await refresh()
    }
    func stop() {
        timer?.invalidate()
        if isDemo { try? FileManager.default.removeItem(at: demoDirectory) }
    }
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let response = try await request(["action": "list"])
            sessions = response.sessions ?? []
            if !sourcePath.isEmpty && !sourceSessions.contains(where: { $0.path == sourcePath }) {
                watchSource = false; setWatching(false); sourcePath = ""; inputsChanged()
            }
            if !targetPath.isEmpty && !targetSessions.contains(where: { $0.path == targetPath }) { targetPath = ""; inputsChanged() }
            if packet == nil { warning = (response.warnings ?? []).joined(separator: "\n") }
            status = "已读取 \(sourceSessions.count) 段 \(sourceProvider.title) 对话、\(targetSessions.count) 段 \(sourceProvider.other.title) 对话。"
        } catch { status = "读取失败：\(error.localizedDescription)" }
    }
    private func persist() {
        guard !isDemo else { return }
        preferences.set(sourceProvider.rawValue, forKey: "sourceProvider")
        preferences.set(sourcePath, forKey: "sourcePath"); preferences.set(targetPath, forKey: "targetPath")
        preferences.set(projectPath, forKey: "projectPath"); preferences.set(intent, forKey: "intent")
    }
    func inputsChanged() {
        packet = nil; hasCopied = false; hasMarked = false; notifiedPacket = ""
        observedStamp = watchSource ? fileStamp() : nil
        persist()
    }
    func selectSource(_ path: String) {
        sourcePath = path
        if let source = selectedSource { projectPath = source.cwd }
        inputsChanged()
        if watchSource { setWatching(true) }
    }
    func selectTarget(_ path: String) { targetPath = path; inputsChanged() }
    func setIntent(_ value: String) { intent = value; inputsChanged() }
    func setPastedText(_ value: String) { pastedText = value; inputsChanged() }
    func setSourceMode(_ value: String) {
        sourceMode = value; inputsChanged()
        if value != "session" { watchSource = false; setWatching(false) }
    }
    func setProvider(_ provider: Provider) {
        guard provider != sourceProvider else { return }
        watchSource = false; setWatching(false)
        sourceProvider = provider; sourcePath = ""; targetPath = ""; pastedText = ""
        intent = provider == .claude ? "implement" : "review"
        inputsChanged()
    }
    func swap() {
        guard !isBusy else { return }
        watchSource = false; setWatching(false)
        let oldSource = sourcePath, oldTarget = targetPath
        sourceProvider = sourceProvider.other
        sourcePath = oldTarget; targetPath = oldSource
        sourceMode = oldTarget.isEmpty ? "paste" : "session"
        pastedText = ""
        intent = sourceProvider == .claude ? "implement" : "review"
        if let source = selectedSource { projectPath = source.cwd }
        status = oldTarget.isEmpty ? "已交换方向。请选择另一方刚完成的对话，或粘贴结果。" : "已交换两边，准备把新增结果交回原对话。"
        inputsChanged()
    }
    func prepare(automatic: Bool = false) async {
        guard canPrepare else { return }
        isBusy = true; defer { isBusy = false }
        var payload: [String: Any] = ["action": "prepare", "target_provider": sourceProvider.other.rawValue, "source_provider": sourceProvider.rawValue, "intent": intent, "project": projectPath]
        if sourceMode == "session" { payload["source_path"] = sourcePath } else { payload["text"] = pastedText }
        if !targetPath.isEmpty { payload["target_path"] = targetPath }
        do {
            let response = try await request(payload)
            packet = response; warning = (response.warnings ?? []).joined(separator: "\n")
            hasCopied = false; hasMarked = false
            status = "已转换 \(response.new_message_count ?? 0) 条新增消息，等待交接到 \(targetProvider.title)。"
            if automatic && autoSwitch && response.source_complete == true && (response.new_message_count ?? 0) > 0 {
                let identity = (response.source?.id ?? sourcePath) + ":" + String(response.message_count ?? 0) + ":" + targetPath
                if notifiedPacket != identity { notifiedPacket = identity; copyAndOpen() }
            }
        } catch { status = "转换失败：\(error.localizedDescription)" }
    }
    func copy() {
        guard let text = clipboardText, !text.isEmpty else { return }
        hasCopied = false
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { status = "写入剪贴板失败，请重新复制。"; return }
        hasCopied = true
        status = "\(copyFullText ? "完整原文" : "交接预览")已复制。在目标对话中按 ⌘V，确认后发送。"
    }
    func copyAndOpen() {
        guard packet != nil else { return }
        copy()
        guard hasCopied else { return }
        guard let url = applicationURL(targetProvider) else {
            status = "内容已复制；未找到 \(targetProvider.title)，请在“应用连接”中选择，或手动切换到原应用。"
            showConnections = true; return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error = error { self.status = "打开失败：\(error.localizedDescription)；交接内容仍在剪贴板。" }
                else { self.status = "已复制并打开 \(url.deletingPathExtension().lastPathComponent)。请在原应用中选择目标对话，粘贴并发送。" }
            }
        }
    }
    func mark() async {
        guard let id = packet?.packet_id, canMark else { return }
        isBusy = true; defer { isBusy = false }
        do {
            _ = try await request(["action": "mark", "packet_id": id])
            hasMarked = true; status = "已记录这次交接。选择“交换两边”可把结果交回。"
        } catch { status = "记录失败：\(error.localizedDescription)" }
    }
    func loadHistory() async {
        guard !isBusy else { return }
        showHistory = true; isBusy = true; defer { isBusy = false }
        do {
            let response = try await request(["action": "history", "limit": 100])
            history = response.history ?? []; historyTotal = response.total ?? 0
            historyWarning = (response.warnings ?? []).joined(separator: "\n")
        } catch { historyWarning = "读取历史失败：\(error.localizedDescription)" }
    }
    func openHistory(_ entry: PacketHistory) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let response = try await request(["action": "read_packet", "packet_id": entry.packet_id])
            watchSource = false; setWatching(false)
            sourceProvider = Provider(rawValue: response.source_provider ?? "") ?? .claude
            for session in [response.source, response.target].compactMap({ $0 }) where !sessions.contains(where: { $0.path == session.path }) {
                sessions.removeAll { $0.id == session.id && $0.provider == session.provider }; sessions.append(session)
            }
            sourcePath = response.source?.path ?? ""; targetPath = response.target?.path ?? ""
            sourceMode = sourcePath.isEmpty ? "paste" : "session"
            pastedText = response.text ?? ""; projectPath = response.project ?? ""; intent = response.intent ?? "continue"
            packet = response; hasCopied = false; hasMarked = response.marked == true
            warning = (response.warnings ?? []).joined(separator: "\n")
            if response.valid == false { warning += "\n此交接包对应的源历史已改变，可查看和复制；请重新转换后确认新的交接。" }
            status = "已打开交接历史：\(entry.dateTitle)。"; showHistory = false; persist()
        } catch { historyWarning = "打开失败：\(error.localizedDescription)" }
    }
    func pasteFromClipboard() {
        guard !isBusy else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { status = "剪贴板里没有文本。"; return }
        setSourceMode("paste"); pastedText = text; inputsChanged(); status = "已读取剪贴板文本，可以转换。"
    }
    func importFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "导入对话或计划"; panel.message = "支持文本、Markdown、JSON 和 JSONL。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isBusy = true; defer { isBusy = false }
            do {
                let response = try await request(["action": "load", "file_path": url.path, "source_provider": sourceProvider.rawValue])
                watchSource = false; setWatching(false)
                if let session = response.session, session.provider == sourceProvider.rawValue, url.pathExtension.lowercased() == "jsonl" {
                    sessions.removeAll { $0.id == session.id && $0.provider == session.provider }; sessions.insert(session, at: 0)
                    sourceMode = "session"; sourcePath = session.path; projectPath = session.cwd
                } else { sourceMode = "paste"; pastedText = response.text ?? "" }
                inputsChanged(); warning = (response.warnings ?? []).joined(separator: "\n"); status = "已导入 \(url.lastPathComponent)。"
            } catch { status = "导入失败：\(error.localizedDescription)" }
        }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.title = "选择交接项目"
        if panel.runModal() == .OK, let url = panel.url { projectPath = url.path; inputsChanged() }
    }
    func applicationURL(_ provider: Provider) -> URL? {
        if let saved = preferences.string(forKey: provider.appPreference), !saved.isEmpty {
            return FileManager.default.fileExists(atPath: saved) ? URL(fileURLWithPath: saved) : nil
        }
        let identifiers = provider == .claude ? ["com.anthropic.claudefordesktop"] : ["com.openai.codex"]
        for id in identifiers { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url } }
        let names = provider == .claude ? ["Claude-Chinese.app", "Claude.app"] : ["Codex.app", "ChatGPT.app"]
        for directory in [NSHomeDirectory() + "/Applications", "/Applications"] {
            for name in names {
                let path = directory + "/" + name
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
    func chooseApp(_ provider: Provider) {
        let panel = NSOpenPanel(); panel.title = "选择 \(provider.title) 应用"; panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "app", Bundle(url: url)?.executableURL != nil else { status = "请选择有效的 macOS 应用（.app）。"; return }
        preferences.set(url.path, forKey: provider.appPreference)
        status = "已连接 \(provider.title)：\(url.lastPathComponent)。"; objectWillChange.send()
    }
    func appPath(_ provider: Provider) -> String { applicationURL(provider)?.path ?? preferences.string(forKey: provider.appPreference) ?? "未发现应用，请选择…" }
    func dataPath(_ provider: Provider) -> String {
        preferences.string(forKey: provider.directoryPreference) ?? ProcessInfo.processInfo.environment[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] ?? NSHomeDirectory() + (provider == .claude ? "/.claude" : "/.codex")
    }
    func chooseDataDirectory(_ provider: Provider) {
        let panel = NSOpenPanel(); panel.title = "选择 \(provider.title) 数据目录"; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = provider == .claude ? "选择包含 projects 文件夹的目录，通常是 ~/.claude。" : "选择包含 sessions 文件夹的目录，通常是 ~/.codex。"
        panel.directoryURL = URL(fileURLWithPath: dataPath(provider))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.set(url.path, forKey: provider.directoryPreference)
        watchSource = false; setWatching(false); inputsChanged(); objectWillChange.send()
        Task { await refresh() }
    }
    func resetDataDirectory(_ provider: Provider) {
        preferences.removeObject(forKey: provider.directoryPreference)
        watchSource = false; setWatching(false); inputsChanged(); objectWillChange.send()
        Task { await refresh() }
    }
    func resetApp(_ provider: Provider) { preferences.removeObject(forKey: provider.appPreference); objectWillChange.send() }
    func showArtifact() { if let path = packet?.artifact_path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    func showStorage() {
        let root = isDemo ? demoDirectory.appendingPathComponent("state") : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DialogueConverter")
        NSWorkspace.shared.open(root)
    }
    func exportPacket() {
        guard !isBusy, let text = packet?.full_text ?? packet?.preview else { return }
        let panel = NSSavePanel(); panel.title = "保存完整交接文件"; panel.nameFieldStringValue = "对话交接-\(packet?.packet_id?.prefix(8) ?? "参考").md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = "完整交接文件已保存。"
        } catch { status = "保存失败：\(error.localizedDescription)" }
    }
    func setWatching(_ enabled: Bool) {
        timer?.invalidate(); timer = nil; observedStamp = nil
        if enabled && sourceMode == "session" && !sourcePath.isEmpty {
            observedStamp = fileStamp()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in await self?.watchTick() } }
            status = "正在等待来源对话的新内容；只在本机文件变化后检查完成状态。"
        }
    }
    private func fileStamp() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath), let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber else { return nil }
        return "\(size.int64Value):\(modified.timeIntervalSince1970)"
    }
    private func watchTick() async {
        guard watchSource, !isBusy, !hasCopied || hasMarked, let stamp = fileStamp(), stamp != observedStamp else { return }
        observedStamp = stamp; isBusy = true
        do {
            let response = try await request(["action": "probe", "source_path": sourcePath, "source_provider": sourceProvider.rawValue])
            isBusy = false
            if response.source_complete == true { await prepare(automatic: true) }
            else { status = "来源有新内容，正在等待明确的完成记录。" }
        } catch {
            isBusy = false; watchSource = false; setWatching(false)
            status = "自动跟随已停止：\(error.localizedDescription)"
        }
    }
}

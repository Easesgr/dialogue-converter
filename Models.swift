import AppKit
import Foundation
import SwiftUI

enum Provider: String, CaseIterable, Identifiable {
    case claude, gpt
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Cowork" : "Codex" }
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
    let surface: String?
    var pickerTitle: String { "\(title.prefix(45)) · \(id.prefix(8))" }
}

struct ConversionRecord: Decodable, Identifiable {
    let id: String
    let created_at: String
    let source: NativeSession
    let target_provider: String
    let title: String
    let project: String
    let message_count: Int
    let state: String
    let artifact_path: String
    let target_id: String?
    let target_path: String?
    var stateTitle: String { state == "imported" ? "已导入" : (state == "exported" ? "待在 Claude 导入" : (state == "prepared" ? "待导入 Codex" : "结果待确认")) }
    var destination: Provider { Provider(rawValue: target_provider) ?? .gpt }
}

struct BridgeResponse: Decodable {
    let conversion: ConversionRecord?
    let conversions: [ConversionRecord]?
    let ok: Bool
    let error: String?
    let sessions: [NativeSession]?
    let warnings: [String]?
    let source: NativeSession?
    let preview: String?
    let characters: Int?
    let message_count: Int?
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
    @Published var projectPath = ""
    @Published var preview = ""
    @Published var messageCount = 0
    @Published var characterCount = 0
    @Published var conversion: ConversionRecord?
    @Published var isBusy = false
    @Published var status = "选择一段本机会话，转换后在目标应用中继续。"
    @Published var warning = ""
    @Published var showConnections = false
    @Published var showHistory = false
    @Published var history: [ConversionRecord] = []
    let isDemo: Bool
    private let demoDirectory: URL
    private let preferences = UserDefaults.standard
    private var previewGeneration = 0

    init(demo: Bool = false) {
        isDemo = demo
        demoDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dialogue-converter-demo-" + UUID().uuidString)
    }
    var sourceSessions: [NativeSession] { sessions.filter { $0.provider == sourceProvider.rawValue && ($0.provider != "claude" || $0.surface == "cowork") } }
    var selectedSource: NativeSession? { sourceSessions.first { $0.path == sourcePath } }
    var canPrepare: Bool { !isBusy && !sourcePath.isEmpty && (sourceProvider == .gpt || !projectPath.isEmpty) }
    var canImport: Bool { !isBusy && conversion?.destination == .gpt && conversion?.state == "prepared" }
    var canContinue: Bool { !isBusy && conversion?.state == "imported" }

    private func request(_ payload: [String: Any]) async throws -> BridgeResponse {
        var configured = payload
        if isDemo {
            configured["data_dir"] = demoDirectory.appendingPathComponent("state").path
            configured["codex_home"] = demoDirectory.appendingPathComponent("codex").path
            configured["claude_home"] = demoDirectory.appendingPathComponent("claude-code").path
            configured["cowork_home"] = demoDirectory.appendingPathComponent("cowork").path
        } else {
            if let path = preferences.string(forKey: "coworkHome") { configured["cowork_home"] = path }
            if let path = preferences.string(forKey: "codexHome") { configured["codex_home"] = path }
        }
        if let app = applicationURL(.gpt) {
            configured["codex_binary"] = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex").path
        }
        return try await BridgeClient.request(configured)
    }
    func start() async {
        if isDemo {
            do { try makeDemo() } catch { status = error.localizedDescription; return }
        }
        await refresh()
        if isDemo, let first = sourceSessions.first {
            sourcePath = first.path
            projectPath = demoDirectory.appendingPathComponent("project").path
            await loadPreview()
        }
    }
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        do {
            let result = try await request(["action": "list"])
            sessions = result.sessions ?? []
            warning = (result.warnings ?? []).joined(separator: "\n")
            let coworkers = sessions.filter { $0.surface == "cowork" }.count
            let codex = sessions.filter { $0.provider == "gpt" }.count
            status = "已读取 \(coworkers) 段 Cowork 与 \(codex) 段 Codex 会话。"
        } catch { status = "读取失败：\(error.localizedDescription)" }
        isBusy = false
    }
    func setProvider(_ provider: Provider) {
        guard !isBusy else { return }
        sourceProvider = provider; sourcePath = ""; clearConversion()
    }
    func selectSource(_ path: String) {
        guard !isBusy else { return }
        sourcePath = path; clearConversion()
        if let session = selectedSource, session.provider == "gpt" { projectPath = session.cwd }
        Task { await loadPreview() }
    }
    private func clearConversion() {
        previewGeneration += 1
        conversion = nil; preview = ""; messageCount = 0; characterCount = 0; warning = ""
    }
    func loadPreview() async {
        guard !sourcePath.isEmpty else { return }
        let generation = previewGeneration, path = sourcePath
        do {
            let result = try await request(["action": "native_preview", "source_path": path])
            guard generation == previewGeneration && path == sourcePath else { return }
            preview = result.preview ?? ""; messageCount = result.message_count ?? 0; characterCount = result.characters ?? 0
            warning = (result.warnings ?? []).joined(separator: "\n")
        } catch {
            if generation == previewGeneration { status = "读取失败：\(error.localizedDescription)" }
        }
    }
    func prepare() async {
        guard canPrepare else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let result = try await request(["action": "native_prepare", "source_path": sourcePath,
                                           "target_provider": sourceProvider.other.rawValue, "project": projectPath])
            conversion = result.conversion; warning = (result.warnings ?? []).joined(separator: "\n")
            status = sourceProvider == .claude ? "格式已转换。点击“导入 Codex”创建原生会话。" : "Cowork 原生导入包已生成。在 Claude 的“导入与导出”中选择此 ZIP。"
        } catch { status = "转换失败：\(error.localizedDescription)" }
    }
    func importNative() async {
        guard canImport, let record = conversion else { return }
        isBusy = true; defer { isBusy = false }
        status = "正在通过 Codex 原生接口导入完整可见历史…"
        do {
            let result = try await request(["action": "native_import", "conversion_id": record.id])
            conversion = result.conversion; warning = (result.warnings ?? []).joined(separator: "\n")
            status = "Codex 原生会话已创建并读回验证。可以打开会话继续。"
        } catch {
            status = "导入未确认：\(error.localizedDescription)"
            if let result = try? await request(["action": "native_read", "conversion_id": record.id]) { conversion = result.conversion }
        }
    }
    func verifyNative() async {
        guard !isBusy, let record = conversion else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let result = try await request(["action": "native_verify", "conversion_id": record.id])
            conversion = result.conversion; warning = (result.warnings ?? []).joined(separator: "\n")
            status = result.conversion?.state == "imported" ? "已在 \(record.destination.title) 读回全部转换消息，可以继续任务。" : "当前资料目录尚未匹配到导入记录，请查看提示。"
        } catch { status = "验证失败：\(error.localizedDescription)" }
    }
    func swap() {
        guard !isBusy else { return }
        if let record = conversion, record.state == "imported", let path = record.target_path {
            sourceProvider = record.destination; sourcePath = path; projectPath = record.project
            clearConversion()
            Task {
                await refresh()
                await loadPreview()
            }
        } else { setProvider(sourceProvider.other) }
    }
    func loadHistory() async {
        guard !isBusy else { return }
        isBusy = true; showHistory = true; defer { isBusy = false }
        do { history = try await request(["action": "native_history"]).conversions ?? [] }
        catch { status = "历史读取失败：\(error.localizedDescription)" }
    }
    func openHistory(_ record: ConversionRecord) {
        guard !isBusy else { return }
        sourceProvider = Provider(rawValue: record.source.provider) ?? .claude
        sourcePath = record.source.path; projectPath = record.project
        clearConversion(); conversion = record; showHistory = false
        Task { await loadPreview() }
    }
    func importFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.title = "选择本机会话文件"
        panel.message = "选择 Cowork 的 local_…json，或 Codex 的 rollout…jsonl。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path; clearConversion()
        let generation = previewGeneration
        Task {
            do {
                let result = try await request(["action": "native_preview", "source_path": url.path])
                guard generation == previewGeneration && sourcePath == url.path else { return }
                if let session = result.source {
                    sessions.removeAll { $0.path == session.path }; sessions.insert(session, at: 0)
                    sourceProvider = Provider(rawValue: session.provider) ?? .claude
                    if session.provider == "gpt" { projectPath = session.cwd }
                }
                preview = result.preview ?? ""; messageCount = result.message_count ?? 0; characterCount = result.characters ?? 0
                warning = (result.warnings ?? []).joined(separator: "\n")
            } catch { if generation == previewGeneration { status = "读取失败：\(error.localizedDescription)" } }
        }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.title = "选择目标项目文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path; conversion = nil
    }
    func applicationURL(_ provider: Provider) -> URL? {
        if let saved = preferences.string(forKey: provider.appPreference), !saved.isEmpty {
            return FileManager.default.fileExists(atPath: saved) ? URL(fileURLWithPath: saved) : nil
        }
        let identifier = provider == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        let names = provider == .claude ? ["Claude-Chinese.app", "Claude.app"] : ["Codex.app", "ChatGPT.app"]
        for directory in [NSHomeDirectory() + "/Applications", "/Applications"] {
            for name in names {
                let path = directory + "/" + name
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
    func openTarget() {
        guard let record = conversion, let app = applicationURL(record.destination) else { showConnections = true; return }
        if record.destination == .gpt, record.state == "imported", let id = record.target_id,
           let url = URL(string: "codex://threads/" + id) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }
    func chooseApp(_ provider: Provider) {
        let panel = NSOpenPanel(); panel.title = "选择 \(provider.title) 应用"
        panel.canChooseDirectories = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "app", Bundle(url: url)?.executableURL != nil else { status = "请选择有效的 .app 应用。"; return }
        preferences.set(url.path, forKey: provider.appPreference); objectWillChange.send()
    }
    func appPath(_ provider: Provider) -> String { applicationURL(provider)?.path ?? "请选择应用…" }
    func dataPath(_ provider: Provider) -> String {
        if provider == .claude { return preferences.string(forKey: "coworkHome") ?? "自动发现 Claude / Claude-3p 的 Cowork 本机记录" }
        return preferences.string(forKey: "codexHome") ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    }
    func chooseDataDirectory(_ provider: Provider) {
        let panel = NSOpenPanel(); panel.title = "选择 \(provider.title) 数据目录"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.showsHiddenFiles = true
        panel.message = provider == .claude ? "选择包含 local-agent-mode-sessions 的 Claude 资料目录。" : "选择包含 sessions 的 Codex 资料目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.set(url.path, forKey: provider == .claude ? "coworkHome" : "codexHome"); objectWillChange.send()
        Task { await refresh() }
    }
    func resetDataDirectory(_ provider: Provider) {
        preferences.removeObject(forKey: provider == .claude ? "coworkHome" : "codexHome"); objectWillChange.send()
        Task { await refresh() }
    }
    func resetApp(_ provider: Provider) { preferences.removeObject(forKey: provider.appPreference); objectWillChange.send() }
    func showArtifact() { if let record = conversion { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.artifact_path)]) } }
    func showStorage() {
        let root = isDemo ? demoDirectory.appendingPathComponent("state") : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DialogueConverter")
        NSWorkspace.shared.open(root)
    }
    func exportPacket() {
        guard !isBusy, let record = conversion else { return }
        let panel = NSSavePanel(); panel.title = "另存原生会话文件"
        panel.nameFieldStringValue = record.destination == .claude ? "Cowork-conversation.zip" : "Claude-native-history.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(contentsOf: URL(fileURLWithPath: record.artifact_path)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = "原生会话文件已保存。"
        } catch { status = "保存失败：\(error.localizedDescription)" }
    }
    private func makeDemo() throws {
        let fm = FileManager.default
        let project = demoDirectory.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let sid = UUID().uuidString.lowercased(), cli = UUID().uuidString.lowercased()
        let root = demoDirectory.appendingPathComponent("cowork/local-agent-mode-sessions/demo/demo")
        let transcript = root.appendingPathComponent("local_" + sid + "/.claude/projects/session/" + cli + ".jsonl")
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let messages = [("user", "为笔记库加一个本机搜索。支持标题和正文，中文关键词可以匹配。先给计划，保持原文件格式。"),
                        ("assistant", "实施计划\n1. 建立标题和正文索引，原文件保持只读。\n2. 增加关键词搜索与结果定位。\n3. 用中文、空查询和无结果验证。\n验收：返回正确笔记，并显示命中段落。"),
                        ("user", "按这个计划实施，完成后把结果交回我审查。")]
        var records: [[String: Any]] = [], parent: Any = NSNull()
        for (role, text) in messages {
            let id = UUID().uuidString.lowercased()
            records.append(["type": role, "uuid": id, "parentUuid": parent, "sessionId": cli,
                            "message": ["role": role, "content": [["type": "text", "text": text]], "stop_reason": "end_turn"]])
            parent = id
        }
        let data = try records.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try data.write(to: transcript, atomically: true, encoding: .utf8)
        let metadata: [String: Any] = ["sessionId": "local_" + sid, "cliSessionId": cli, "title": "笔记库本机搜索计划"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("local_" + sid + ".json"))
    }
}

import AppKit
import SwiftUI

private let accent = Color(red: 0.16, green: 0.34, blue: 0.66)
private let ink = Color(red: 0.12, green: 0.16, blue: 0.22)

struct ConverterView: View {
    @ObservedObject var model: ConverterModel
    @State private var search = ""
    private var sources: [NativeSession] {
        model.sourceSessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.cwd.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Divider()
                workspace
            }
            Divider()
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "externaldrive").foregroundStyle(.secondary) }
                Text(model.status).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button { model.showConnections = true } label: { Image(systemName: "slider.horizontal.3") }.help("应用连接与数据目录")
            }.padding(.horizontal, 22).padding(.vertical, 12)
        }
        .foregroundStyle(ink)
        .background(Color.white)
        .frame(minWidth: 960, minHeight: 680)
        .tint(accent)
        .sheet(isPresented: $model.showConnections) { connections }
        .sheet(isPresented: $model.showHistory) { history }
        .task { await model.start() }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.swap").font(.system(size: 26, weight: .medium)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("对话转换器").font(.system(size: 22, weight: .semibold))
                Text("转换原生会话，在原应用继续任务").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.sourceProvider.title).fontWeight(.medium)
            Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                .help("交换方向；已导入时选择目标会话交回").accessibilityLabel("交换方向").disabled(model.isBusy)
            Text(model.sourceProvider.other.title).fontWeight(.medium)
            Divider().frame(height: 26).padding(.horizontal, 10)
            Button { Task { await model.loadHistory() } } label: { Label("转换记录", systemImage: "clock.arrow.circlepath") }.disabled(model.isBusy)
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本机会话").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新本机会话").accessibilityLabel("刷新会话").disabled(model.isBusy)
            }
            Picker("来源应用", selection: Binding(get: { model.sourceProvider }, set: model.setProvider)) {
                Text("Cowork").tag(Provider.claude); Text("Codex").tag(Provider.gpt)
            }.pickerStyle(.segmented).disabled(model.isBusy)
            TextField("搜索会话名称或项目", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(sources) { session in
                        Button { model.selectSource(session.path) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(session.title).font(.system(size: 13, weight: session.path == model.sourcePath ? .semibold : .regular)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Text(session.updated_at.prefix(10)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(session.path == model.sourcePath ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(model.isBusy)
                    }
                    if sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("没有找到本机会话").font(.system(size: 13, weight: .medium))
                            Text("请确认任务已保存到本机，或在应用连接中选择数据目录。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.vertical, 22)
                    }
                }
            }
            Divider()
            Button("选择会话文件…", action: model.importFile).disabled(model.isBusy)
            Text("读取 Cowork 与 Codex 本机记录。源会话保持只读。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(Color(red: 0.965, green: 0.972, blue: 0.982))
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source = model.selectedSource {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(source.title).font(.system(size: 20, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        Text("\(model.messageCount) 条可见消息，\(model.characterCount.formatted()) 字符").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("原文预览", systemImage: "text.alignleft").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(24)
            }
            if model.preview.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "doc.on.doc").font(.system(size: 38, weight: .light)).foregroundStyle(accent)
                    Text("把任务的历史带过去").font(.system(size: 25, weight: .semibold))
                    Text("选择一段 Cowork 或 Codex 会话。用户要求、计划与回复会按原来的顺序转换成目标应用的会话记录。").font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(6).frame(maxWidth: 450, alignment: .leading)
                    Text("模型调用与接下来的工作，都在原应用中完成。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    Text(model.preview).font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if model.sourceProvider == .claude {
                    HStack {
                        Label("Codex 项目", systemImage: "folder").font(.system(size: 12, weight: .medium))
                        Text(model.projectPath.isEmpty ? "选择继续实施的本机文件夹" : model.projectPath)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("选择…", action: model.chooseProject).disabled(model.isBusy)
                    }
                }
                if let record = model.conversion {
                    HStack {
                        Image(systemName: record.state == "imported" ? "checkmark.circle.fill" : "doc.badge.arrow.up")
                            .foregroundStyle(record.state == "imported" ? Color.green : accent)
                        Text(record.stateTitle).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("另存…", action: model.exportPacket)
                        Button("显示文件", action: model.showArtifact)
                    }
                    if record.destination == .claude && record.state != "imported" {
                        Text("在 Claude 的“设置 → 导入与导出”中导入生成的 Cowork ZIP，然后点“检查导入结果”。原生导入入口随 Claude 版本与账号配置而异。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if record.destination == .gpt && record.state == "prepared" {
                            Button("导入 Codex") { Task { await model.importNative() } }.buttonStyle(.borderedProminent).disabled(!model.canImport)
                        } else if record.destination == .gpt && record.target_id != nil && record.state != "imported" {
                            Button("重新检查导入结果") { Task { await model.verifyNative() } }.buttonStyle(.borderedProminent)
                        } else if record.destination == .claude && record.state != "imported" {
                            Button("打开 Claude", action: model.openTarget).buttonStyle(.borderedProminent)
                            Button("检查导入结果") { Task { await model.verifyNative() } }.disabled(model.isBusy)
                        } else if record.state == "imported" {
                            Button("在 \(record.destination.title) 继续", action: model.openTarget).buttonStyle(.borderedProminent)
                            Button("选择目标会话交回", action: model.swap)
                        }
                    }.disabled(model.isBusy)
                } else {
                    HStack {
                        Text(model.sourceProvider == .claude ? "创建新的 Codex 原生会话" : "生成 Cowork 原生导入包")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("转换会话") { Task { await model.prepare() } }.buttonStyle(.borderedProminent).disabled(!model.canPrepare).keyboardShortcut(.return, modifiers: .command)
                    }
                }
                if !model.warning.isEmpty {
                    Text(model.warning).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.padding(20).background(Color(red: 0.985, green: 0.988, blue: 0.994))
        }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("应用连接").font(.system(size: 22, weight: .semibold))
            ForEach(Provider.allCases) { provider in
                VStack(alignment: .leading, spacing: 10) {
                    Text(provider.title).font(.headline)
                    Text(model.appPath(provider)).font(.system(size: 12)).textSelection(.enabled)
                    HStack { Button("选择应用…") { model.chooseApp(provider) }; Button("自动发现") { model.resetApp(provider) } }
                    Text(model.dataPath(provider)).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack { Button("选择数据目录…") { model.chooseDataDirectory(provider) }; Button("恢复默认目录") { model.resetDataDirectory(provider) } }
                }
                Divider()
            }
            Text("转换器不调用模型。导入 Codex 使用已安装桌面端的原生接口；导入 Cowork 由 Claude 自己的历史导入界面完成。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Button("打开转换资料目录", action: model.showStorage); Spacer(); Button("完成") { model.showConnections = false }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 620)
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("转换记录").font(.system(size: 22, weight: .semibold)); Spacer(); Button("完成") { model.showHistory = false }.keyboardShortcut(.cancelAction) }
            if model.history.isEmpty { Text("转换后的记录会保存在本机，便于继续导入或交回。").foregroundStyle(.secondary) }
            List(model.history) { record in
                Button { model.openHistory(record) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title).fontWeight(.medium)
                        Text("\(record.destination.title) · \(record.message_count) 条消息 · \(record.stateTitle)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.buttonStyle(.plain).disabled(model.isBusy)
            }
        }.padding(24).frame(width: 640, height: 480)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = ConverterModel(demo: CommandLine.arguments.contains("--demo"))
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "对话转换器"; window.minSize = NSSize(width: 960, height: 680)
        window.setFrameAutosaveName("DialogueConverterNativeMain")
        window.contentView = NSHostingView(rootView: ConverterView(model: model))
        if !window.setFrameUsingName("DialogueConverterNativeMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    private func item(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem { let i = NSMenuItem(title: title, action: selector, keyEquivalent: key); i.target = self; return i }
    private func buildMenu() {
        let menu = NSMenu(), app = NSMenu()
        app.addItem(item("关于对话转换器", #selector(about))); app.addItem(.separator()); app.addItem(item("应用连接…", #selector(connections), ",")); app.addItem(.separator())
        app.addItem(NSMenuItem(title: "退出对话转换器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let file = NSMenu(title: "文件")
        file.addItem(item("选择会话文件…", #selector(importFile), "o")); file.addItem(item("另存原生会话文件…", #selector(exportFile), "s")); file.addItem(item("刷新本机会话", #selector(refresh), "r"))
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); fileItem.submenu = file; menu.addItem(fileItem)
        let conversion = NSMenu(title: "转换")
        conversion.addItem(item("转换会话", #selector(prepare), "\r"))
        conversion.addItem(item("导入 Codex", #selector(importNative)))
        let swap = item("交换方向", #selector(swap), "x"); swap.keyEquivalentModifierMask = [.command, .shift]; conversion.addItem(swap)
        let history = item("转换记录…", #selector(history), "h"); history.keyEquivalentModifierMask = [.command, .shift]; conversion.addItem(history)
        let conversionItem = NSMenuItem(title: "转换", action: nil, keyEquivalent: ""); conversionItem.submenu = conversion; menu.addItem(conversionItem)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        let help = NSMenu(title: "帮助"); help.addItem(item("使用说明与源代码", #selector(helpPage)))
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: ""); helpItem.submenu = help; menu.addItem(helpItem)
        NSApp.mainMenu = menu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(prepare): return model.canPrepare
        case #selector(importNative): return model.canImport
        case #selector(exportFile): return !model.isBusy && model.conversion != nil
        case #selector(refresh), #selector(importFile), #selector(swap), #selector(history): return !model.isBusy
        default: return true
        }
    }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "对话转换器", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .credits: NSAttributedString(string: "Claude Cowork ⇄ Codex\n本机原生会话转换\nMIT License · Easesgr")]) }
    @objc private func connections() { model.showConnections = true }
    @objc private func importFile() { model.importFile() }
    @objc private func exportFile() { model.exportPacket() }
    @objc private func refresh() { Task { await model.refresh() } }
    @objc private func prepare() { Task { await model.prepare() } }
    @objc private func importNative() { Task { await model.importNative() } }
    @objc private func swap() { model.swap() }
    @objc private func history() { Task { await model.loadHistory() } }
    @objc private func helpPage() { NSWorkspace.shared.open(URL(string: "https://github.com/Easesgr/dialogue-converter#readme")!) }
}

@main
struct ConverterApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

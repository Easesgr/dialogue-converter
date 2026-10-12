import AppKit
import SwiftUI

private let ink = Color(red: 0.15, green: 0.20, blue: 0.18)
private let accent = Color(red: 0.18, green: 0.40, blue: 0.33)

struct ConverterView: View {
    @ObservedObject var model: ConverterModel
    @State private var search = ""
    @State private var historyFilter = "all"
    private var filteredSources: [NativeSession] {
        model.sourceSessions.filter { $0.path == model.sourcePath || search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.cwd.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                sourceColumn.frame(width: 365)
                Divider()
                previewColumn
            }.frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .foregroundStyle(ink)
        .background(Color(red: 0.97, green: 0.965, blue: 0.945))
        .frame(minWidth: 960, minHeight: 650)
        .sheet(isPresented: $model.showConnections) { connections }
        .sheet(isPresented: $model.showHistory) { historyView }
        .task { await model.start() }
        .onChange(of: model.watchSource) { _, enabled in model.setWatching(enabled) }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "arrow.triangle.swap").font(.system(size: 29, weight: .medium)).foregroundStyle(accent).frame(width: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text("对话转换器").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("只转换与交接，对话留在原应用").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.loadHistory() } } label: { Label("交接历史", systemImage: "clock.arrow.circlepath") }
                .disabled(model.isBusy)
            HStack(spacing: 10) {
                providerBadge(model.sourceProvider)
                Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right").font(.system(size: 14, weight: .medium)) }
                    .help("交换两边，交回新增结果").accessibilityLabel("交换两边").disabled(model.isBusy)
                providerBadge(model.sourceProvider.other)
            }
            .padding(10).background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 26).padding(.vertical, 20)
    }
    private func providerBadge(_ provider: Provider) -> some View {
        HStack(spacing: 6) { Circle().fill(provider.color).frame(width: 7, height: 7); Text(provider.title).font(.system(size: 13, weight: .medium)) }
    }
    private var sourceColumn: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack { step("01", "选择来源"); Spacer(); Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新本机对话").accessibilityLabel("刷新对话").disabled(model.isBusy) }
            Picker("来源应用", selection: Binding(get: { model.sourceProvider }, set: model.setProvider)) { ForEach(Provider.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).disabled(model.isBusy)
            Picker("来源方式", selection: Binding(get: { model.sourceMode }, set: model.setSourceMode)) { Text("本机对话").tag("session"); Text("粘贴 / 导入").tag("paste") }.pickerStyle(.segmented).disabled(model.isBusy)
            if model.sourceMode == "session" {
                TextField("筛选名称或项目", text: $search).textFieldStyle(.roundedBorder)
                Picker("来源对话", selection: Binding(get: { model.sourcePath }, set: model.selectSource)) {
                    Text("请选择一段对话").tag("")
                    ForEach(filteredSources) { Text($0.pickerTitle).tag($0.path) }
                }.labelsHidden().frame(maxWidth: .infinity).disabled(model.isBusy)
                if let source = model.selectedSource {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(source.title).font(.system(size: 14, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                        Text(source.cwd.isEmpty ? "来源未记录项目目录" : source.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        Label(source.complete ? "已识别完成记录" : "尚未确认完成", systemImage: source.complete ? "checkmark.circle" : "clock").font(.system(size: 11)).foregroundStyle(source.complete ? accent : .secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("选择已经完成的计划或结果").font(.system(size: 13, weight: .medium))
                        Text("未出现在列表中的桌面对话，可复制内容后切换到“粘贴 / 导入”。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8)
                }
            } else {
                Text("原对话或已完成的计划").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { model.pastedText }, set: model.setPastedText)).font(.system(size: 12)).scrollContentBackground(.hidden).padding(7).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.22))).frame(height: 175).accessibilityLabel("原对话或计划").disabled(model.isBusy)
            }
            HStack { Button("读取剪贴板", action: model.pasteFromClipboard); Button("导入文件…", action: model.importFile) }.font(.system(size: 12)).disabled(model.isBusy)
            Divider()
            step("02", "选择去向")
            Picker("目标对话", selection: Binding(get: { model.targetPath }, set: model.selectTarget)) {
                Text("在 \(model.sourceProvider.other.title) 新建 / 手动选择").tag("")
                ForEach(model.targetSessions) { Text($0.pickerTitle).tag($0.path) }
            }.labelsHidden().disabled(model.isBusy)
            Text(model.targetPath.isEmpty ? "到目标应用中选择或新建对话。下次可绑定到同一对话。" : "绑定此目标的交接进度。打开应用后，请选择这段对话再粘贴。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("交接目的", selection: Binding(get: { model.intent }, set: model.setIntent)) { Text("按计划实施").tag("implement"); Text("审查实施结果").tag("review"); Text("继续当前任务").tag("continue") }.disabled(model.isBusy)
            HStack { Text("项目").font(.system(size: 12)).foregroundStyle(.secondary); Text(model.projectPath.isEmpty ? "沿用来源项目" : URL(fileURLWithPath: model.projectPath).lastPathComponent).font(.system(size: 12)).lineLimit(1); Spacer(); Button("选择…", action: model.chooseProject).disabled(model.isBusy) }.help(model.projectPath)
        }.padding(22)
        }
            Divider()
            Button { Task { await model.prepare() } } label: { Label(model.isBusy ? "处理中…" : "转换交接内容", systemImage: "arrow.triangle.swap").frame(maxWidth: .infinity).padding(.vertical, 5) }.buttonStyle(.borderedProminent).tint(accent).disabled(!model.canPrepare)
                .padding(22)
        }.frame(maxHeight: .infinity, alignment: .top).background(Color(red: 0.935, green: 0.934, blue: 0.912))
    }
    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { step("03", "交接预览"); Spacer(); if let p = model.packet { Text("\(p.new_message_count ?? 0) 条新增 · \(p.characters ?? 0) 字符").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) } }
            if let packet = model.packet {
                ScrollView {
                    Text(packet.preview ?? "").font(.system(size: 13)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(18)
                }.background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.gray.opacity(0.18)))
                if !(model.warning.isEmpty) {
                    ScrollView { Text(model.warning).font(.system(size: 11)).foregroundStyle(Color(red: 0.51, green: 0.34, blue: 0.18)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 65)
                }
                HStack { Button("查看完整文件", action: model.showArtifact); Button("另存为…", action: model.exportPacket); Spacer(); Label("本机转换", systemImage: "lock").font(.system(size: 11)).foregroundStyle(.secondary) }
                Picker("复制内容", selection: $model.copyFullText) {
                    Text("简洁交接").tag(false)
                    Text("完整原文").tag(true)
                }.pickerStyle(.segmented).disabled(model.isBusy)
                if packet.preview != packet.full_text {
                    Text(model.copyFullText ? "复制全部可见原文（\(packet.full_text?.count ?? 0) 字符）。" : "简洁交接包含完整原文的本机文件引用。若目标应用无法读文件，请选“完整原文”或附加导出的文件。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "doc.on.doc").font(.system(size: 38, weight: .light)).foregroundStyle(accent.opacity(0.8))
                    Text("把计划交给下一位。").font(.system(size: 25, weight: .medium, design: .serif))
                    Text("Claude 完成规划，在 Codex 中实施。\nCodex 完成后，把结果交回 Claude 检查。").font(.system(size: 14)).lineSpacing(8).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("两边继续使用自己的界面和会话", systemImage: "macwindow")
                        Label("再次交接时，只转换新增内容", systemImage: "text.badge.plus")
                        Label("转换在本机完成，无额外模型调用", systemImage: "bolt")
                    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack(spacing: 10) {
                Button { model.copyAndOpen() } label: { Label("复制并打开 \(model.targetProvider.title)", systemImage: "arrow.up.forward.app").padding(.vertical, 5).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(accent).disabled(!model.canCopy)
                Button("仅复制", action: model.copy).disabled(!model.canCopy)
            }
            HStack {
                Text("在目标对话按 ⌘V 粘贴，再用原应用发送。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(model.hasMarked ? "交接已记录 ✓" : "已在原应用发送") { Task { await model.mark() } }.font(.system(size: 11)).disabled(!model.canMark)
            }
            Divider()
            HStack {
                Toggle("跟随来源更新", isOn: $model.watchSource).toggleStyle(.checkbox).disabled(model.sourceMode != "session" || model.sourcePath.isEmpty || model.isBusy)
                Spacer()
                Toggle("完成后复制并切换", isOn: $model.autoSwitch).toggleStyle(.checkbox).disabled(!model.watchSource)
            }.font(.system(size: 11))
            Text("自动切换仅在识别到来源完成时执行；发送仍在原应用中完成。").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var footer: some View {
        HStack(spacing: 10) {
            if model.isBusy { ProgressView().controlSize(.small) } else { Circle().fill(accent).frame(width: 6, height: 6) }
            Text(model.status).font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
            Spacer()
            Button("应用连接…") { model.showConnections = true }.font(.system(size: 11))
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private func step(_ number: String, _ title: String) -> some View {
        HStack(spacing: 9) { Text(number).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(accent); Text(title).font(.system(size: 14, weight: .semibold)) }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("应用连接").font(.title2.weight(.semibold))
            Text("指定你平时使用的两个桌面应用。转换器只打开应用并复制交接内容，发送操作由原应用完成。").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Provider.allCases) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { providerBadge(provider); Spacer(); Button("自动查找") { model.resetApp(provider) }; Button("选择应用…") { model.chooseApp(provider) } }
                    Text(model.appPath(provider)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    Divider()
                    HStack { Text("本机对话数据").font(.system(size: 12)); Spacer(); Button("默认") { model.resetDataDirectory(provider) }; Button("选择目录…") { model.chooseDataDirectory(provider) } }
                    Text(model.dataPath(provider)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                }.padding(14).background(Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(model.isBusy || model.isDemo)
            }
            Text("本机对话列表来自可读取的 Claude Code 与 Codex 会话记录。Claude 网页聊天或部分 Cowork 会话可通过复制、导出文件导入。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完成") { model.showConnections = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 590)
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("交接历史").font(.title2.weight(.semibold)); Spacer(); if model.isBusy { ProgressView().controlSize(.small) } }
            Text("重新打开、复制或导出已准备的交接内容。确认发送后才会推进增量交接进度。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("显示", selection: $historyFilter) { Text("全部").tag("all"); Text("待确认").tag("pending"); Text("已确认发送").tag("marked") }.pickerStyle(.segmented)
            if model.history.isEmpty && !model.isBusy {
                ContentUnavailableView("暂无交接记录", systemImage: "clock.arrow.circlepath", description: Text("转换一段对话后，交接包会保存在本机。"))
            } else {
                List(model.history.filter { historyFilter == "all" || (historyFilter == "marked" ? $0.marked : !$0.marked && $0.valid) }) { entry in
                    Button { Task { await model.openHistory(entry) } } label: {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text("\(entry.direction) · \(entry.new_message_count) 条消息").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(entry.dateTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.stateTitle).font(.system(size: 11)).foregroundStyle(entry.marked ? accent : .secondary)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                }.listStyle(.inset)
            }
            if !model.historyWarning.isEmpty { Text(model.historyWarning).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("显示最近 \(model.history.count) 条，共 \(model.historyTotal) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("本机资料…", action: model.showStorage)
                Spacer()
                Button("完成") { model.showHistory = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 640, height: 490)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "对话转换器"; window.minSize = NSSize(width: 960, height: 650)
        window.setFrameAutosaveName("DialogueConverterMain")
        window.contentView = NSHostingView(rootView: ConverterView(model: model))
        if !window.setFrameUsingName("DialogueConverterMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    private func item(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem { let i = NSMenuItem(title: title, action: selector, keyEquivalent: key); i.target = self; return i }
    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenu(); app.addItem(item("关于对话转换器", #selector(about))); app.addItem(.separator()); app.addItem(item("应用连接…", #selector(connections), ",")); app.addItem(.separator())
        let quit = NSMenuItem(title: "退出对话转换器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); app.addItem(quit)
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let file = NSMenu(title: "文件"); file.addItem(item("导入对话…", #selector(importFile), "o")); file.addItem(item("保存交接文件…", #selector(exportFile), "s")); file.addItem(item("刷新本机对话", #selector(refresh), "r"))
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); fileItem.submenu = file; menu.addItem(fileItem)
        let handoff = NSMenu(title: "交接")
        handoff.addItem(item("转换交接内容", #selector(prepare), "\r"))
        let switchItem = item("复制并打开目标应用", #selector(copyAndOpen), "\r"); switchItem.keyEquivalentModifierMask = [.command, .shift]; handoff.addItem(switchItem)
        let swapItem = item("交换两边", #selector(swap), "x"); swapItem.keyEquivalentModifierMask = [.command, .shift]; handoff.addItem(swapItem)
        let historyItem = item("交接历史…", #selector(history), "h"); historyItem.keyEquivalentModifierMask = [.command, .shift]; handoff.addItem(historyItem)
        let pasteItem = item("从剪贴板导入", #selector(pasteImport), "v"); pasteItem.keyEquivalentModifierMask = [.command, .shift]; handoff.addItem(pasteItem)
        let handoffItem = NSMenuItem(title: "交接", action: nil, keyEquivalent: ""); handoffItem.submenu = handoff; menu.addItem(handoffItem)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        let windowMenu = NSMenu(title: "窗口"); windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        let help = NSMenu(title: "帮助"); help.addItem(item("使用说明与源代码", #selector(helpPage)))
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: ""); helpItem.submenu = help; menu.addItem(helpItem)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(prepare): return model.canPrepare
        case #selector(copyAndOpen), #selector(exportFile): return model.canCopy
        case #selector(refresh), #selector(importFile), #selector(swap), #selector(history), #selector(pasteImport): return !model.isBusy
        default: return true
        }
    }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "对话转换器", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .version: "原生 macOS · 本机转换", .credits: NSAttributedString(string: "Claude ⇄ Codex\n转换交接资料，对话留在原应用。\nMIT License · Easesgr")]) }
    @objc private func connections() { model.showConnections = true }
    @objc private func importFile() { model.importFile() }
    @objc private func exportFile() { model.exportPacket() }
    @objc private func refresh() { Task { await model.refresh() } }
    @objc private func prepare() { Task { await model.prepare() } }
    @objc private func copyAndOpen() { model.copyAndOpen() }
    @objc private func swap() { model.swap() }
    @objc private func history() { Task { await model.loadHistory() } }
    @objc private func pasteImport() { model.pasteFromClipboard() }
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

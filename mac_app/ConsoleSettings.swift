import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConsoleItem: Identifiable {
    let id: String
    let name: String
    let kind: String
    let target: String
    let shell: String
    var typeName: String { kind == "subscription" ? "订阅更新" : kind == "app" ? "应用" : kind == "script" ? "Shell 脚本" : "Shell 命令" }
}

struct ConsoleSettings: View {
    @ObservedObject var model: ControlModel
    @ViewState private var editor = false
    @ViewState private var editing: ConsoleItem?
    @ViewState private var deleting: ConsoleItem?
    @ViewState private var dropTarget: String?
    private func move(_ id: String, to target: ConsoleItem) {
        Task {
            await model.perform(["action": "console-move", "id": id, "targetID": target.id], success: "顺序已保存")
            if !model.failed { await model.loadConsole() }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("配置后，已配对网页可运行这些项目。拖动左侧手柄可在同组内排序。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("添加项目") { editing = nil; editor = true }.buttonStyle(.borderedProminent)
            }
            if model.consoleItems.isEmpty {
                Text("暂无快捷项目，添加一个应用或脚本开始使用。")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(["app", "script", "command", "subscription"], id: \.self) { kind in
                let items = model.consoleItems.filter { $0.kind == kind }
                if !items.isEmpty {
                    Text(kind == "subscription" ? "订阅更新" : kind == "app" ? "应用" : kind == "script" ? "脚本" : "命令").font(.headline)
                    ForEach(items) { item in
                        GroupBox {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary).frame(width: 20, height: 40)
                                    .contentShape(Rectangle())
                                    .help("拖动以调整同组顺序").accessibilityLabel("拖动排序 " + item.name)
                                    .accessibilityAction(named: Text("上移")) {
                                        if let index = items.firstIndex(where: { $0.id == item.id }), index > 0 { move(item.id, to: items[index - 1]) }
                                    }
                                    .accessibilityAction(named: Text("下移")) {
                                        if let index = items.firstIndex(where: { $0.id == item.id }), index + 1 < items.count { move(item.id, to: items[index + 1]) }
                                    }
                                if item.kind == "app" {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.target)).resizable().frame(width: 40, height: 40)
                                } else {
                                    Image(systemName: item.kind == "script" ? "doc.text" : "terminal").font(.title2).foregroundStyle(Color.accentColor).frame(width: 40, height: 40)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.name).font(.headline)
                                    Text(item.typeName).font(.caption).foregroundStyle(.secondary)
                                    Text(item.target).font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                                }
                                Spacer()
                                Button("编辑") { editing = item; editor = true }
                                Button("删除", role: .destructive) { deleting = item }.foregroundStyle(.red)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(object: item.id as NSString) }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(dropTarget == item.id ? 0.7 : 0), lineWidth: 2).allowsHitTesting(false))
                        .onDrop(of: [UTType.utf8PlainText], isTargeted: Binding(get: { dropTarget == item.id }, set: { targeted in
                            if targeted { dropTarget = item.id }
                            else if dropTarget == item.id { dropTarget = nil }
                        })) { providers in
                            guard !model.busy, providers.count == 1 else { return false }
                            providers[0].loadObject(ofClass: NSString.self) { value, _ in
                                guard let id = value as? String else { return }
                                Task { @MainActor in
                                    guard !model.busy, id != item.id,
                                          model.consoleItems.contains(where: { $0.id == id && $0.kind == item.kind }) else { return }
                                    // 释放时只提交源与目标，避免悬停过程反复写入或覆盖新配置。
                                    dropTarget = nil
                                    move(id, to: item)
                                }
                            }
                            return true
                        }
                    }
                }
            }
            Button("刷新列表") { Task { await model.loadConsole() } }
            Text("应用在这台 Mac 上打开；脚本后台执行，以脚本所在目录为工作目录，Shell 命令以用户主目录为工作目录。一次运行一个项目，最多等待 5 分钟；不支持终端交互输入。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.loadConsole() }
        .sheet(isPresented: $editor) { ConsoleItemEditor(model: model, item: editing) }
        .alert("删除快捷项目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                guard let item = deleting else { return }; deleting = nil
                Task {
                    await model.perform(["action": "console-delete", "id": item.id], success: "快捷项目已删除")
                    if !model.failed { await model.loadConsole() }
                }
            }
        } message: { Text("只移除控制台入口，不删除应用或脚本文件；已经启动的任务会继续运行。") }
    }
}

struct ConsoleItemEditor: View {
    @ObservedObject var model: ControlModel
    let item: ConsoleItem?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String
    @ViewState private var kind: String
    @ViewState private var target: String
    @ViewState private var shell: String
    init(model: ControlModel, item: ConsoleItem?) {
        self.model = model; self.item = item
        _name = ViewState(initialValue: item?.name ?? "")
        _kind = ViewState(initialValue: item?.kind ?? "app")
        _target = ViewState(initialValue: item?.target ?? "")
        _shell = ViewState(initialValue: item?.shell ?? "/bin/zsh")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item == nil ? "添加快捷项目" : "编辑快捷项目").font(.title2.bold())
            TextField("显示名称", text: $name).textFieldStyle(.roundedBorder)
            Picker("类型", selection: $kind) {
                Text("应用").tag("app")
                Text("脚本文件").tag("script")
                Text("Shell 命令").tag("command")
                Text("订阅更新").tag("subscription")
            }.pickerStyle(.segmented).onChange(of: kind) { _ in target = kind == "subscription" ? "all" : "" }
            if kind == "subscription" {
                Picker("更新范围", selection: $target) {
                    Text("全部订阅").tag("all")
                    ForEach(["paoluz", "sc", "just"], id: \.self) { Text($0).tag($0) }
                }
                Text("使用这台 Mac 现有的订阅更新脚本，保留校验和失败回滚；仅在网页确认执行后更新。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == "command" {
                Text("Shell 命令").font(.headline)
                TextEditor(text: $target).font(.system(.body, design: .monospaced)).frame(height: 130)
                    .border(Color.secondary.opacity(0.3)).accessibilityLabel("Shell 命令内容")
            } else {
                HStack {
                    TextField(kind == "app" ? "应用路径（.app）" : "Shell 脚本路径", text: $target).textFieldStyle(.roundedBorder)
                    Button("选择文件…") { chooseFile() }
                }
            }
            if kind == "script" || kind == "command" {
                Picker("解释器", selection: $shell) {
                    Text("zsh").tag("/bin/zsh"); Text("bash").tag("/bin/bash")
                }
                Text("点击网页项目后，会以当前 Mac 用户身份执行。请使用无需交互输入的 Shell 脚本或命令；路径和命令内容只保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.failed { Text(model.message).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    var body: [String: Any] = ["action": "console-save", "name": name, "kind": kind, "target": target, "shell": shell]
                    if let item { body["id"] = item.id }
                    Task {
                        await model.perform(body, success: "快捷项目已保存")
                        if !model.failed { await model.loadConsole(); if !model.failed { dismiss() } }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540).disabled(model.busy)
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if kind == "app" { panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = url.path
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }
}

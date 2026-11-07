import SwiftUI
import AppKit

// SDK 同时导出同名宏；别名明确使用包装器，避免依赖 Xcode 的宏插件。
typealias ViewState<Value> = SwiftUI.State<Value>

struct LANAddress: Identifiable {
    let id: String
    let label: String
    let url: String
}

struct ManagedKey: Identifiable {
    let id: String
    let name: String
    let maskedKey: String
}

@MainActor final class ControlModel: ObservableObject {
    @Published var url = "https://ipad.iamxg.com"
    @Published var token = ""
    @Published var dashboard = "正在检查…"
    @Published var music = "正在检查…"
    @Published var musicLogin = false
    @Published var appLogin = false
    @Published var paired = false
    @Published var pairingCode = ""
    @Published var pairingExpiresAt: Double = 0
    @Published var lanAddresses: [LANAddress] = []
    @Published var keys: [ManagedKey] = []
    @Published var busy = false
    @Published var message = ""
    @Published var failed = false
    @Published var connectedURL = ""

    nonisolated static func request(_ payload: [String: Any]) throws -> [String: Any] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/iPadService")
        process.arguments = ["--request"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // 口令和 Key 只经过标准输入，不进入进程参数、URL 或日志。
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "控制服务未正常返回", code: 1)
        }
        if let error = result["error"] as? String { throw NSError(domain: error, code: 1) }
        guard process.terminationStatus == 0 else { throw NSError(domain: "原生服务未正常返回", code: 1) }
        return result
    }

    func perform(_ payload: [String: Any], success: String = "", completion: (([String: Any]) -> Void)? = nil) async {
        guard !busy else { return }
        busy = true; failed = false; message = "正在处理…"
        do {
            let result = try await Task.detached { try Self.request(payload) }.value
            completion?(result)
            message = success
        } catch {
            failed = true
            message = (error as NSError).domain
        }
        busy = false
    }

    func refresh(initial: Bool = false) async {
        await perform(["action": "status"]) { result in
            self.dashboard = result["dashboard"] as? String ?? "未知"
            self.music = result["music"] as? String ?? "未知"
            self.musicLogin = result["musicLogin"] as? Bool ?? false
            self.appLogin = result["appLogin"] as? Bool ?? false
            self.paired = result["paired"] as? Bool ?? false
            self.pairingCode = result["pairingCode"] as? String ?? ""
            self.pairingExpiresAt = result["pairingExpiresAt"] as? Double ?? 0
            self.lanAddresses = (result["lanAddresses"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, let label = $0["label"] as? String, let url = $0["url"] as? String else { return nil }
                return LANAddress(id: id, label: label, url: url)
            }
            self.connectedURL = result["url"] as? String ?? ""
            if initial { self.url = self.connectedURL }
        }
    }

    func service(_ action: String, enabled: Bool? = nil) async {
        var body: [String: Any] = ["action": action]
        if let enabled { body["enabled"] = enabled }
        await perform(body, success: "设置已更新")
        if !failed { await refresh() }
    }

    func loadKeys() async {
        keys = []
        await perform(["action": "keys"], success: "已读取当前看板的 Key") { result in
            self.keys = (result["keys"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, let name = $0["name"] as? String,
                      let masked = $0["maskedKey"] as? String else { return nil }
                return ManagedKey(id: id, name: name, maskedKey: masked)
            }
        }
    }
}

struct ControlView: View {
    @StateObject private var model = ControlModel()
    @ViewState private var section = "服务"
    @ViewState private var editingID: String?
    @ViewState private var name = ""
    @ViewState private var key = ""
    @ViewState private var deleting: ManagedKey?

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("服务概览", systemImage: "switch.2").tag("服务")
                Label("看板连接", systemImage: "network").tag("连接")
                Label("公司 Key", systemImage: "key.horizontal").tag("Key")
            }
            .navigationTitle("iPad 控制台")
            .navigationSplitViewColumnWidth(170)
            .disabled(model.busy)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section == "服务" ? "让大屏保持在线" : section == "连接" ? "连接你的看板" : "公司 Key")
                            .font(.largeTitle.bold())
                        Text(section == "服务" ? "在这台 Mac 上管理服务与登录启动" : "当前管理：\(model.connectedURL)")
                            .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if section == "服务" { services }
                        else if section == "连接" { connection }
                        else { keySettings }
                    }.padding(2)
                }
                Text(model.message).font(.callout)
                    .foregroundStyle(model.failed ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(model.message)
            }.padding(28).disabled(model.busy)
        }
        .frame(minWidth: 820, minHeight: 620)
        .task { await model.refresh(initial: true) }
        .onChange(of: section) { value in
            resetEditor()
            Task { if value == "Key" { await model.loadKeys() } else { await model.refresh() } }
        }
        .alert("删除 Key？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                guard let item = deleting else { return }
                deleting = nil
                Task {
                    await model.perform(["action": "key-delete", "id": item.id])
                    if !model.failed { resetEditor(); await model.loadKeys() }
                }
            }
        } message: { Text("将从 \(model.connectedURL) 删除“\(deleting?.name ?? "")”，不会撤销服务商的 Key。") }
    }

    var services: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("本地看板 · 原生服务") {
                VStack(alignment: .leading, spacing: 12) {
                    status(model.dashboard)
                    HStack {
                        Button("启动看板") { Task { await model.service("dashboard-start") } }
                        Button("停止看板") { Task { await model.service("dashboard-stop") } }
                        Spacer()
                        Button("打开本地看板") { open("http://127.0.0.1:18088") }
                    }
                    Text("由 App 内置后台提供服务，无需 Docker。停止本地看板不影响线上站点。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("网页配对") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.paired {
                        Text("已配对").font(.headline).foregroundStyle(.green)
                        Text("打开 ipad.iamxg.com，输入配对码后即可查看这台 Mac 的内容。")
                    } else if !model.pairingCode.isEmpty {
                        Text("在网页输入下面的配对码")
                        Text(model.pairingCode).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                        Text("8 位配对码有效期约 10 分钟；网页完成配对后这里会自动变为已配对。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("正在生成配对码，或暂时无法连接配对服务…").foregroundStyle(.secondary)
                    }
                    Button("刷新配对码") { Task { await model.refresh() } }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("音乐与歌词同步") {
                VStack(alignment: .leading, spacing: 12) {
                    status(model.music)
                    HStack {
                        Button("启动同步") { Task { await model.service("music-start") } }
                        Button("停止同步") { Task { await model.service("music-stop") } }
                    }
                    Toggle("登录 Mac 时启动后台服务", isOn: Binding(get: { model.musicLogin }, set: { enabled in
                        Task { await model.service("music-login", enabled: enabled) }
                    }))
                    Text("同时服务本地和线上看板；停止后，两端歌词和播放控制将离线。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("登录 Mac 时打开控制台", isOn: Binding(get: { model.appLogin }, set: { enabled in
                Task { await model.service("app-login", enabled: enabled) }
            }))
            Text("退出控制台不会停止后台服务。Codex 状态由原生采集器直接读取。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("刷新状态") { Task { await model.refresh() } }
                Button("打开线上看板") { open("https://ipad.iamxg.com") }
            }
        }
    }

    var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ipadAddresses
            GroupBox("管理目标") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button("线上看板") { model.url = "https://ipad.iamxg.com" }
                        Button("本地看板") { model.url = "http://127.0.0.1:18088" }
                    }
                    TextField("看板地址", text: $model.url).textFieldStyle(.roundedBorder)
                    SecureField("访问口令（留空沿用已保存的口令）", text: $model.token).textFieldStyle(.roundedBorder)
                    Text("沿用迁入钥匙串的看板口令。保存前会验证连接；只设置此 App 的管理目标，不修改看板服务的口令或音乐同步地址。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("验证并保存连接") {
                        Task {
                            await model.perform(["action": "connection-save", "url": model.url, "token": model.token], success: "连接验证通过，已保存") { _ in
                                model.connectedURL = model.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                model.token = ""; model.keys = []; resetEditor()
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                    Text("口令保存在 macOS 钥匙串中。iPad 首次连接仍需输入看板口令。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var ipadAddresses: some View {
        GroupBox("iPad 访问地址") {
            VStack(alignment: .leading, spacing: 12) {
                Text("线上：https://ipad.iamxg.com").textSelection(.enabled)
                Text("局域网：iPad 与 Mac 需在可互通的同一网络，首次访问需输入看板口令。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.lanAddresses) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label).font(.caption).foregroundStyle(.secondary)
                            Text(item.url).textSelection(.enabled)
                        }
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.url, forType: .string)
                        }.accessibilityLabel("复制 " + item.label + " 访问地址")
                    }
                }
                if model.lanAddresses.isEmpty { Text("未检测到可用的 Wi-Fi 或网线 IPv4 地址").foregroundStyle(.secondary) }
                Text("127.0.0.1 仅供这台 Mac 使用。局域网地址随网络变化，请刷新；Mac 需保持开机并运行看板服务。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新网络地址") { Task { await model.refresh() } }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var keySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地与线上配置独立；这里的修改立即作用于上方所示看板。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.keys) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline)
                        Text(item.maskedKey).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑") { editingID = item.id; name = item.name; key = "" }
                    Button("删除", role: .destructive) { deleting = item }
                }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.keys.isEmpty { Text("暂无 Key，或尚未连接成功").foregroundStyle(.secondary) }
            GroupBox(editingID == nil ? "添加 Key" : "编辑 Key") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("备注名", text: $name).textFieldStyle(.roundedBorder)
                    SecureField(editingID == nil ? "API Key" : "API Key（留空保留原值）", text: $key).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存") {
                            Task {
                                var body: [String: Any] = ["action": "key-save", "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "key": key.trimmingCharacters(in: .whitespacesAndNewlines)]
                                if let editingID { body["id"] = editingID }
                                await model.perform(body)
                                if !model.failed { resetEditor(); await model.loadKeys() }
                            }
                        }.buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (editingID == nil && key.isEmpty))
                        Button("清空 / 新增") { resetEditor() }
                        Spacer()
                        Button("刷新列表") { Task { await model.loadKeys() } }
                    }
                }.padding(12)
            }
        }
    }

    func status(_ value: String) -> some View {
        Label(value, systemImage: value == "运行中" ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(value == "运行中" ? Color.green : Color.secondary)
    }
    func resetEditor() { editingID = nil; name = ""; key = "" }
    func open(_ address: String) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
}

@main struct IPadControlApp: App {
    var body: some Scene {
        Window("iPad 控制台", id: "main") { ControlView() }
            .defaultSize(width: 900, height: 680)
    }
}

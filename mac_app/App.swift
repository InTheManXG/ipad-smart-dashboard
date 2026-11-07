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
    @Published var dashboard = "正在检查…"
    @Published var music = "正在检查…"
    @Published var musicLogin = false
    @Published var appLogin = false
    @Published var paired = false
    @Published var localPairingCode = ""
    @Published var pairingCode = ""
    @Published var pairingExpiresAt: Double = 0
    @Published var lanAddresses: [LANAddress] = []
    @Published var station: [String: String]?
    @Published var keys: [ManagedKey] = []
    @Published var keysLoaded = false
    @Published var busy = false
    @Published var message = ""
    @Published var failed = false

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

    func refresh() async {
        await perform(["action": "status"]) { result in
            self.dashboard = result["dashboard"] as? String ?? "未知"
            self.music = result["music"] as? String ?? "未知"
            self.musicLogin = result["musicLogin"] as? Bool ?? false
            self.appLogin = result["appLogin"] as? Bool ?? false
            self.paired = result["paired"] as? Bool ?? false
            self.localPairingCode = result["localPairingCode"] as? String ?? ""
            self.pairingCode = result["pairingCode"] as? String ?? ""
            self.pairingExpiresAt = result["pairingExpiresAt"] as? Double ?? 0
            self.lanAddresses = (result["lanAddresses"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, let label = $0["label"] as? String, let url = $0["url"] as? String else { return nil }
                return LANAddress(id: id, label: label, url: url)
            }
        }
    }

    func service(_ action: String, enabled: Bool? = nil) async {
        var body: [String: Any] = ["action": action]
        if let enabled { body["enabled"] = enabled }
        await perform(body, success: "设置已更新")
        if !failed { await refresh() }
    }

    func loadKeys() async {
        guard !busy else { return }
        keys = []; keysLoaded = false
        await perform(["action": "keys"], success: "已读取中转站 Key") { result in
            self.station = result["station"] as? [String: String]
            self.keysLoaded = true
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
    @ViewState private var stationEditor = false
    @ViewState private var stationName = ""
    @ViewState private var stationURL = ""
    @ViewState private var confirmStationChange = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("服务管理", systemImage: "switch.2").tag("服务")
                Label("连接与配对", systemImage: "network").tag("连接")
                Label("中转站 Key", systemImage: "key.horizontal").tag("Key")
            }
            .navigationTitle("iPad 控制台")
            .navigationSplitViewColumnWidth(170)
            .disabled(model.busy)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section == "服务" ? "服务管理" : section == "连接" ? "连接与配对" : "中转站 Key")
                            .font(.largeTitle.bold())
                        Text(section == "服务" ? "管理这台 Mac 的后台服务与登录启动" : section == "连接" ? "选择连接方式，在 iPad 上打开对应地址并配对" : "管理这台 Mac 的中转站 Key")
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
        .task { await model.refresh() }
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
        } message: { Text("将从这台 Mac 删除“\(deleting?.name ?? "")”，不会撤销服务商的 Key。") }
    }

    var services: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("本地看板 · 原生服务") {
                VStack(alignment: .leading, spacing: 12) {
                    status(model.dashboard)
                    HStack {
                        Button("启动看板") { Task { await model.service("dashboard-start") } }
                        Button("停止看板") { Task { await model.service("dashboard-stop") } }
                    }
                    Text("由 App 内置后台提供服务，无需 Docker。停止本地看板不影响线上站点。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("音乐与歌词同步") {
                VStack(alignment: .leading, spacing: 12) {
                    status(model.music)
                    HStack {
                        Button("启动同步") { Task { await model.service("music-start") } }
                        Button("停止同步") { Task { await model.service("music-stop") } }
                    }
                    Text("同时服务本地和线上看板；停止后，两端歌词和播放控制将离线。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("登录启动") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录 Mac 时启动后台服务", isOn: Binding(get: { model.musicLogin }, set: { enabled in
                        Task { await model.service("music-login", enabled: enabled) }
                    }))
                    Toggle("登录 Mac 时打开控制台", isOn: Binding(get: { model.appLogin }, set: { enabled in
                        Task { await model.service("app-login", enabled: enabled) }
                    }))
                    Text("退出控制台不会停止后台服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("刷新服务状态") { Task { await model.refresh() } }
        }
    }

    var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("公网连接") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("https://ipad.iamxg.com").textSelection(.enabled)
                        Spacer()
                        Button("打开公网看板") { open("https://ipad.iamxg.com") }
                    }
                    if model.paired {
                        Label("已配对", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("在已配对的浏览器中打开上方地址，即可查看这台 Mac 的内容。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !model.pairingCode.isEmpty {
                        Text("在网页输入配对码")
                        Text(model.pairingCode).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
                        Text("配对码 10 分钟有效，只能使用一次。完成后点击下方按钮刷新状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("尚未取得公网配对码，请确认后台服务和网络连接正常。")
                            .foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            // 仅在本地监听就绪时提供局域网入口，避免展示无法访问的地址。
            if model.dashboard == "运行中" {
                GroupBox("局域网连接") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("iPad 与 Mac 连接可互通的网络，打开以下任一地址。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.lanAddresses) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                                    Text(item.url).textSelection(.enabled)
                                }
                                Spacer()
                                Button("复制地址") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.url, forType: .string)
                                }.accessibilityLabel("复制 " + item.label + " 访问地址")
                            }
                        }
                        if model.lanAddresses.isEmpty {
                            Text("未检测到可用的 Wi-Fi 或网线地址").foregroundStyle(.secondary)
                        }
                        Divider()
                        if !model.localPairingCode.isEmpty {
                            Text("本地配对码")
                            Text(model.localPairingCode).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
                            Text("配对码 10 分钟有效，使用后更新。与公网配对码分别使用。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("正在准备本地配对码，请稍后刷新。").foregroundStyle(.secondary)
                        }
                        Button("在这台 Mac 上打开") { open("http://127.0.0.1:18088") }
                        Text("此方式无需公网服务。Mac 需保持开机；HTTP 地址仅用于可信局域网。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("刷新连接状态与地址") { Task { await model.refresh() } }
        }
    }

    var keySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.keysLoaded {
                if let station = model.station {
                    GroupBox("中转站") {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(station["name"] ?? "Sub2API").font(.headline)
                                Text("Sub2API · " + (station["url"] ?? "")).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("编辑中转站") { openStationEditor() }
                        }.padding(10)
                    }
                    Text("Key 保存在这台 Mac 的钥匙串中，公网与局域网共用；目前支持一个 Sub2API 站点。")
                        .font(.callout).foregroundStyle(.secondary)
                    stationKeys
                } else {
                    Text("先添加一个 Sub2API 中转站，再配置该站的 Key。当前支持一个站点。")
                        .foregroundStyle(.secondary)
                    Button("添加中转站") { openStationEditor() }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("中转站配置尚未加载成功，请刷新重试。").foregroundStyle(.secondary)
            }
            Button("刷新列表") { Task { await model.loadKeys() } }
        }
        .sheet(isPresented: $stationEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.station == nil ? "添加中转站" : "编辑中转站").font(.title2.bold())
                Text("类型：Sub2API（当前仅支持此类型）").foregroundStyle(.secondary)
                TextField("中转站名称", text: $stationName).textFieldStyle(.roundedBorder)
                TextField("站点地址，例如 https://sub2api.example.com", text: $stationURL).textFieldStyle(.roundedBorder)
                Text("填写 HTTPS 根地址，也支持以 /v1 结尾的 API 地址。保存后再添加 Key。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.failed { Text(model.message).foregroundStyle(.red) }
                HStack {
                    Button("取消") { stationEditor = false }
                    Spacer()
                    Button("保存中转站") {
                        if !model.keys.isEmpty && stationURL != model.station?["url"] { confirmStationChange = true }
                        else { Task { await saveStation(confirmed: false) } }
                    }.buttonStyle(.borderedProminent)
                        .disabled(stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 480).disabled(model.busy)
            .confirmationDialog("更换中转站地址？", isPresented: $confirmStationChange, titleVisibility: .visible) {
                Button("确认更换地址") { Task { await saveStation(confirmed: true) } }
                Button("取消", role: .cancel) { }
            } message: { Text("已有 Key 将用于向新地址查询额度。请确认该地址属于这些 Key 的中转站。") }
        }
    }

    func openStationEditor() {
        stationName = model.station?["name"] ?? ""
        stationURL = model.station?["url"] ?? ""
        model.failed = false
        stationEditor = true
    }
    func saveStation(confirmed: Bool) async {
        await model.perform(["action": "station-save", "type": "sub2api", "name": stationName, "url": stationURL, "confirmAddressChange": confirmed])
        if !model.failed { stationEditor = false; await model.loadKeys() }
    }

    var stationKeys: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            if model.keys.isEmpty {
                Text(model.keysLoaded ? "暂无中转站 Key，可在下方添加。" : "Key 列表尚未加载成功，请刷新重试。")
                    .foregroundStyle(.secondary)
            }
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

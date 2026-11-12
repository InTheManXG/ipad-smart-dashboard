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

struct PairedScreen: Identifiable {
    let id: String
    let scope: String
    let remark: String
    let ua: String
}

@MainActor final class ControlModel: ObservableObject {
    @Published var dashboard = "正在检查…"
    @Published var musicEnabled = false
    @Published var musicLogin = false
    @Published var appLogin = false
    @Published var publicURL = ""
    @Published var paired = false
    @Published var publicScreens: [PairedScreen] = []
    @Published var localScreens: [PairedScreen] = []
    @Published var consoleItems: [ConsoleItem] = []
    @Published var publicScreensError = ""
    @Published var extraCode = ""
    @Published var extraCodeExpiry: Double = 0
    private var extraCodeCount = 0
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
            self.musicEnabled = result["musicEnabled"] as? Bool ?? false
            self.musicLogin = result["musicLogin"] as? Bool ?? false
            self.appLogin = result["appLogin"] as? Bool ?? false
            let address = result["publicURL"] as? String ?? ""
            if self.publicURL != address { self.extraCode = ""; self.publicScreens = [] }
            self.publicURL = address
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

    func loadScreens() async {
        await perform(["action": "screens"]) { result in
            func screens(_ key: String, scope: String) -> [PairedScreen] {
                (result[key] as? [[String: Any]] ?? []).compactMap {
                    guard let id = $0["id"] as? String else { return nil }
                    return PairedScreen(id: id, scope: scope, remark: $0["remark"] as? String ?? "", ua: $0["ua"] as? String ?? "")
                }
            }
            self.publicScreens = screens("publicScreens", scope: "public")
            self.localScreens = screens("localScreens", scope: "local")
            self.publicScreensError = result["publicError"] as? String ?? ""
            if self.publicScreens.count > self.extraCodeCount || Date().timeIntervalSince1970 >= self.extraCodeExpiry { self.extraCode = "" }
        }
    }
    func refreshConnections() async { await refresh(); if !failed { await loadScreens() } }
    func newCode() async {
        await perform(["action": "pairing-code"], success: "请在新网页输入此码；完成后刷新列表。") { result in
            self.extraCode = result["code"] as? String ?? ""
            self.extraCodeExpiry = result["expiresAt"] as? Double ?? 0
            self.extraCodeCount = result["screenCount"] as? Int ?? self.publicScreens.count
        }
    }

    func loadConsole() async {
        await perform(["action": "console-list"]) { result in
            self.consoleItems = (result["items"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, let name = $0["name"] as? String,
                      let kind = $0["kind"] as? String, let target = $0["target"] as? String else { return nil }
                return ConsoleItem(id: id, name: name, kind: kind, target: target, shell: $0["shell"] as? String ?? "/bin/zsh")
            }
        }
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
    @ViewState private var publicEditor = false
    @ViewState private var editingScreen: PairedScreen?
    @ViewState private var kickingScreen: PairedScreen?
    @ViewState private var expandedScreens: Set<String> = []

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("服务管理", systemImage: "switch.2").tag("服务")
                Label("连接与配对", systemImage: "network").tag("连接")
                Label("快捷控制台", systemImage: "square.grid.2x2").tag("控制台")
                Label("音乐同步", systemImage: "music.note").tag("音乐")
                Label("中转站 Key", systemImage: "key.horizontal").tag("Key")
            }
            .navigationTitle("iPad 控制台")
            .navigationSplitViewColumnWidth(170)
            .disabled(model.busy)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section == "服务" ? "服务管理" : section == "连接" ? "连接与配对" : section == "控制台" ? "快捷控制台" : section == "音乐" ? "音乐同步" : "中转站 Key")
                            .font(.largeTitle.bold())
                        Text(section == "服务" ? "管理这台 Mac 的后台服务与登录启动" : section == "连接" ? "选择连接方式，在 iPad 上打开对应地址并配对" : section == "控制台" ? "配置网页左侧的应用和脚本快捷入口" : section == "音乐" ? "控制看板的音乐与歌词显示" : "管理这台 Mac 的中转站 Key")
                            .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if section == "控制台" {
                    ConsoleSettings(model: model)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if section == "服务" { services }
                            else if section == "连接" { connection }
                            else if section == "音乐" { musicSettings }
                            else { keySettings }
                        }.padding(2)
                    }
                }
                Text(model.message).font(.callout)
                    .foregroundStyle(model.failed ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .accessibilityLabel(model.message)
            }.padding(28).disabled(model.busy)
        }
        .frame(minWidth: 820, minHeight: 620)
        .task { await model.refresh() }
        .onChange(of: section) { value in
            resetEditor()
            Task { if value == "Key" { await model.loadKeys() } else if value == "连接" { await model.refreshConnections() } else if value != "控制台" { await model.refresh() } }
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
            GroupBox("登录启动") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录 Mac 时启动后台服务", isOn: Binding(get: { model.musicLogin }, set: { enabled in
                        Task { await model.service("music-login", enabled: enabled) }
                    }))
                    Toggle("登录 Mac 时打开控制台", isOn: Binding(get: { model.appLogin }, set: { enabled in
                        Task { await model.service("app-login", enabled: enabled) }
                    }))
                    Text("关闭窗口后可从菜单栏重新打开；退出控制台会停止后台服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("刷新服务状态") { Task { await model.refresh() } }
        }
    }

    var musicSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("音乐与歌词") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用音乐同步", isOn: Binding(get: { model.musicEnabled }, set: { enabled in
                        Task { await model.service(enabled ? "music-start" : "music-stop") }
                    }))
                    Text("启用后，网页显示音乐、歌词和播放控制；关闭后隐藏整个音乐区域，任务现场占满剩余空间。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("同时作用于公网和局域网看板，不会退出或暂停 Mac 上的音乐播放器。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("刷新同步状态") { Task { await model.refresh() } }
        }
    }

    var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("公网连接") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.publicURL.isEmpty ? "尚未配置公网服务" : model.publicURL).textSelection(.enabled)
                        Spacer()
                        if !model.publicURL.isEmpty { Button("打开公网看板") { open(model.publicURL) } }
                        Button("配置地址") { model.failed = false; publicEditor = true }
                    }
                    if model.publicURL.isEmpty {
                        Text("填写你部署的看板服务地址，保存后获取配对码。").foregroundStyle(.secondary)
                    } else if model.paired {
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
                    if !model.publicURL.isEmpty {
                        Button("配对新网页") { Task { await model.newCode() } }
                        if !model.extraCode.isEmpty {
                            Text(model.extraCode).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
                            Text("10 分钟有效、仅使用一次；不会断开已配对的网页。").font(.caption).foregroundStyle(.secondary)
                        }
                        if !model.publicScreensError.isEmpty { Text(model.publicScreensError).foregroundStyle(.red) }
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
                            Text("配对新网页 · 本地配对码")
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
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("已配对网页").font(.title3.bold())
                    Text("\(visibleScreens.count)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新连接状态与地址") { Task { await model.refreshConnections() } }
                }
                Text("公网和局域网分别最多配对 16 个网页；可为每个端添加位置备注，UA 为浏览器上报信息。")
                    .font(.caption).foregroundStyle(.secondary)
                screenCards
            }
        }
        .sheet(isPresented: $publicEditor) { PublicAddressEditor(model: model) }
        .sheet(item: $editingScreen) { ScreenRemarkEditor(model: model, screen: $0) }
        .confirmationDialog("将此网页踢下线？", isPresented: Binding(get: { kickingScreen != nil }, set: { if !$0 { kickingScreen = nil } }), titleVisibility: .visible) {
            Button("踢下线", role: .destructive) {
                guard let screen = kickingScreen else { return }
                kickingScreen = nil
                Task {
                    await model.perform(["action": "screen-kick", "scope": screen.scope, "id": screen.id], success: "该网页已下线")
                    if !model.failed { await model.refreshConnections() }
                }
            }
            Button("取消", role: .cancel) { kickingScreen = nil }
        } message: {
            Text("“\(kickingScreen?.remark.isEmpty == false ? kickingScreen!.remark : "未备注网页")”将失去访问权限，需要重新配对。其他端不受影响。")
        }
    }

    private var visibleScreens: [PairedScreen] {
        model.publicScreens + (model.dashboard == "运行中" ? model.localScreens : [])
    }

    var screenCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            if visibleScreens.isEmpty {
                Text(model.publicScreensError.isEmpty ? "暂无已配对网页，可使用上方配对码连接新设备。" : "网页列表暂不可用，请刷新重试。")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            // 一个会话一张卡片，连接类型保留在卡片内，公共说明只在列表上方展示。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(visibleScreens) { screen in
                    let detailID = screen.scope + ":" + screen.id
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "display").font(.title2).foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(screen.remark.isEmpty ? "未备注网页" : screen.remark)
                                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(screen.scope == "public" ? "公网" : "局域网")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.05), in: Capsule())
                            }
                            Spacer(minLength: 4)
                            Button("编辑备注") { editingScreen = screen }
                                .controlSize(.small)
                            Button("踢下线", role: .destructive) { kickingScreen = screen }
                                .controlSize(.small).foregroundStyle(.red)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(userAgentSummary(screen.ua)).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button {
                                    if expandedScreens.contains(detailID) { expandedScreens.remove(detailID) }
                                    else { expandedScreens.insert(detailID) }
                                } label: {
                                    Label("详细信息", systemImage: expandedScreens.contains(detailID) ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                                .fixedSize().accessibilityValue(expandedScreens.contains(detailID) ? "已展开" : "已收起")
                            }
                            if expandedScreens.contains(detailID) {
                                Text(screen.ua.isEmpty ? "尚未上报，请在对应网页刷新。" : screen.ua)
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }
                        }
                    }
                    // 收起详情时按内容高度布局，不为隐藏的 UA 预留空白。
                    .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                }
            }
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

struct ScreenRemarkEditor: View {
    @ObservedObject var model: ControlModel
    let screen: PairedScreen
    @Environment(\.dismiss) private var dismiss
    @ViewState private var note: String
    init(model: ControlModel, screen: PairedScreen) {
        self.model = model; self.screen = screen; _note = ViewState(initialValue: screen.remark)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("网页备注").font(.title2.bold())
            TextField("例如：办公室 iPad、客厅大屏", text: $note).textFieldStyle(.roundedBorder)
            Text("UA：" + (screen.ua.isEmpty ? "尚未上报" : screen.ua)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.failed { Text(model.message).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    Task {
                        await model.perform(["action": "screen-remark", "scope": screen.scope, "id": screen.id, "remark": note], success: "备注已保存")
                        if !model.failed { dismiss(); await model.loadScreens() }
                    }
                }.buttonStyle(.borderedProminent).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).count > 80)
            }
        }.padding(24).frame(width: 480).disabled(model.busy)
    }
}

// 表单独立持有草稿，让首次弹出时的按钮校验与输入值保持同步。
struct PublicAddressEditor: View {
    @ObservedObject var model: ControlModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var address: String
    init(model: ControlModel) {
        self.model = model
        _address = ViewState(initialValue: model.publicURL)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("公网服务地址").font(.title2.bold())
            TextField("https://你的看板域名", text: $address).textFieldStyle(.roundedBorder)
            Text("填写已部署本项目配对服务的 HTTPS 根地址。保存后，任务、额度与音乐数据会同步到该服务；更换服务器需在对应网页重新配对。")
                .font(.callout).foregroundStyle(.secondary)
            if model.failed { Text(model.message).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("验证并保存") {
                    Task {
                        await model.perform(["action": "public-save", "url": address], success: "公网地址已保存")
                        if !model.failed { dismiss(); await model.refresh() }
                    }
                }.buttonStyle(.borderedProminent).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480).disabled(model.busy)
    }
}

@MainActor final class ControlAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 登录时后台启动不抢占窗口，但 Dock 与菜单栏始终提供返回入口。
        if CommandLine.arguments.contains("--background") { NSApp.hide(nil) }
        Task {
            do { _ = try await Task.detached { try ControlModel.request(["action": "service-start"]) }.value }
            catch { showFailure("后台服务启动失败", error) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 先卸载 launchd 服务再退出，防止 KeepAlive 留下没有控制入口的后台。
        Task {
            do {
                _ = try await Task.detached { try ControlModel.request(["action": "service-stop"]) }.value
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                showFailure("后台服务停止失败", error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func showFailure(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = (error as NSError).domain
        alert.runModal()
    }
}

struct ControlMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("打开 iPad 控制台") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 iPad 控制台（停止后台服务）") { NSApp.terminate(nil) }
    }
}

@main struct IPadControlApp: App {
    @NSApplicationDelegateAdaptor(ControlAppDelegate.self) private var delegate
    var body: some Scene {
        Window("iPad 控制台", id: "main") { ControlView() }
            .defaultSize(width: 900, height: 680)
        MenuBarExtra("iPad 控制台", systemImage: "ipad.landscape") { ControlMenu() }
    }
}

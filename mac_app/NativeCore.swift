import Foundation
import Security
import CryptoKit
import Darwin
import SystemConfiguration
import IOKit

typealias JSONObject = [String: Any]
struct ControlError: Error { let message: String; init(_ message: String) { self.message = message } }
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
func jsonObject(_ data: Data) throws -> JSONObject {
    guard let value = try JSONSerialization.jsonObject(with: data) as? JSONObject else { throw ControlError("数据格式不正确") }
    return value
}
func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}
func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
func secretValid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 } }
func secureEqual(_ left: String, _ right: String) -> Bool {
    let a = Array(SHA256.hash(data: Data(left.utf8))), b = Array(SHA256.hash(data: Data(right.utf8)))
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
func endpoint(_ string: String) throws -> URL {
    guard let parts = URLComponents(string: string), let host = parts.host, !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/", !string.contains(where: { $0.isWhitespace }),
          parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
          parts.port == nil || (1...65535).contains(parts.port!), let url = parts.url else {
        throw ControlError("仅支持 HTTPS 根地址或本机 HTTP，不含账号、路径和查询参数")
    }
    return url
}

enum NativePaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let data = home.appendingPathComponent("Library/Application Support/iPadControl", isDirectory: true)
    static let config = data.appendingPathComponent("settings.json")
    static let app = Bundle.main.bundleURL
    static let resources = Bundle.main.resourceURL!
    static let service = app.appendingPathComponent("Contents/MacOS/iPadService")
    static let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    static let label = "com.iamxg.ipad-native"
    static private(set) var identitySuffix = ""
    static var domain: String { "gui/\(getuid())" }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        identitySuffix = try InstallationBinding.prepare(directory: data, hardwareHash: InstallationBinding.hardwareHash())
    }
    static func identityAccount(_ name: String) -> String { InstallationBinding.account(name, suffix: identitySuffix) }
}

// 安装身份与硬件绑定，防止迁移助理复制钥匙串后两台 Mac 共用配对和控制权限。
enum InstallationBinding {
    static func hardwareHash() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw ControlError("无法确认本机身份，暂不启动配对服务") }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              UUID(uuidString: value) != nil else { throw ControlError("无法确认本机身份，暂不启动配对服务") }
        return SHA256.hash(data: Data(value.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func account(_ name: String, suffix: String) -> String {
        suffix.isEmpty ? name : name + "-installation-" + suffix
    }
    static func prepare(directory: URL, hardwareHash: String) throws -> String {
        guard hardwareHash.count == 64, hardwareHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ControlError("本机身份格式不正确") }
        let fm = FileManager.default, path = directory.appendingPathComponent("installation.json")
        let fd = open(path.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ControlError("无法锁定安装身份") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ControlError("无法锁定安装身份") }
        defer { _ = flock(fd, LOCK_UN) }
        var previous: JSONObject?
        if fm.fileExists(atPath: path.path) {
            previous = try readJSON(path)
            guard previous?["schema"] as? Int == 1, let hash = previous?["hardwareHash"] as? String,
                  hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let suffix = previous?["keychainSuffix"] as? String,
                  suffix.isEmpty || UUID(uuidString: suffix) != nil else { throw ControlError("安装身份配置不可读，拒绝复用旧配对") }
            if hash == hardwareHash { return suffix }
        }
        // 已安装的旧版首次升级保留原账户；新安装和异机副本获得独立的账户后缀。
        let legacy = previous == nil && fm.fileExists(atPath: directory.appendingPathComponent("settings.json").path)
        let suffix = legacy ? "" : UUID().uuidString.lowercased()
        var moved = [(URL, URL)](), archive: URL?
        do {
            if previous != nil {
                let destination = directory.appendingPathComponent("device-migrations", isDirectory: true).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                archive = destination
                // 只隔离配对会话和运行快照，站点、Key、控制台和设置继续由用户保留。
                for name in ["local-screens.json", "cloud-permissions.json", "runtime.json"] {
                    let source = directory.appendingPathComponent(name), target = destination.appendingPathComponent(name)
                    if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: target); moved.append((source, target)) }
                }
            }
            try writeJSON(["schema": 1, "hardwareHash": hardwareHash, "keychainSuffix": suffix], path)
        } catch {
            for (source, target) in moved.reversed() { try? fm.moveItem(at: target, to: source) }
            if let archive, (try? fm.contentsOfDirectory(atPath: archive.path).isEmpty) == true { try? fm.removeItem(at: archive) }
            throw error
        }
        return suffix
    }
}

enum Secrets {
    static let service = "com.iamxg.ipad-control.native"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func get(_ account: String) throws -> String? {
        var q = query(account); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ControlError("无法读取钥匙串，请解锁登录钥匙串")
        }
        return value
    }
    static func set(_ account: String, _ value: String) throws {
        guard secretValid(value) else { throw ControlError("口令或 Key 格式不正确") }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var code = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            var q = query(account); q.merge(attributes) { _, new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            code = SecItemAdd(q as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw ControlError("无法保存到登录钥匙串") }
    }
    static func delete(_ account: String) throws {
        let code = SecItemDelete(query(account) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(code) else { throw ControlError("无法删除钥匙串条目") }
    }
}

func readJSON(_ url: URL) throws -> JSONObject { try jsonObject(Data(contentsOf: url)) }
func writeJSON(_ value: Any, _ url: URL) throws {
    try jsonData(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
func configuration() throws -> JSONObject {
    if !FileManager.default.fileExists(atPath: NativePaths.config.path) {
        return ["publicURL": "", "musicEnabled": false, "dashboardEnabled": false, "musicLogin": false]
    }
    return try readJSON(NativePaths.config)
}
func displayToken() throws -> String {
    let account = NativePaths.identityAccount("display-token")
    if let token = try Secrets.get(account) { return token }
    // 全新安装自行生成本机凭据，无需从旧 Docker 项目迁入。
    let token = UUID().uuidString + UUID().uuidString
    try Secrets.set(account, token)
    return token
}

// 缺少字段代表升级前的安装；新安装显式保存空值，不自动连接公共服务器。
func publicAddress(_ config: JSONObject) -> String { config["publicURL"] as? String ?? "" }
struct PairingConnection {
    let base: URL
    init(config: JSONObject) throws {
        let address = publicAddress(config)
        guard !address.isEmpty else { throw ControlError("请先配置公网服务地址") }
        base = try endpoint(address)
    }
    func url(_ path: String) -> URL { base.appendingPathComponent(path) }
    func account(_ name: String) -> String {
        // 原站点沿用原凭据，其余地址隔离，切换地址不能泄露旧令牌。
        let origin = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if origin == "https://ipad.iamxg.com" { return NativePaths.identityAccount(name) }
        let suffix = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return NativePaths.identityAccount(name + "-" + suffix)
    }
    func token() throws -> String? { try Secrets.get(account("device-token")) }
    func deviceID() throws -> String {
        if let value = try Secrets.get(account("device-id")), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased(); try Secrets.set(account("device-id"), value); return value
    }
}
func validatePublicAddress(_ address: String) throws -> String {
    let base = try endpoint(trimmed(address))
    guard let result = try HTTPFetch.request(base.appendingPathComponent("api/mode"), timeout: 8) as? JSONObject,
          result["mode"] as? String == "pairing" else { throw ControlError("该地址不是支持配对的看板服务") }
    return base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
func pairingStart() throws -> JSONObject {
    let target = try PairingConnection(config: configuration())
    let token = try target.token() ?? (UUID().uuidString.lowercased() + UUID().uuidString.lowercased())
    let body: JSONObject = ["deviceId": try target.deviceID(), "deviceToken": token, "name": Host.current().localizedName ?? "Mac App"]
    guard let result = try HTTPFetch.request(target.url("api/pairing/register"), token: token, body: body, header: "X-Device-Token") as? JSONObject else { throw ControlError("配对服务返回无效数据") }
    if try target.token() == nil { try Secrets.set(target.account("device-token"), token) }
    if result["paired"] as? Bool == true { return result }
    guard let code = try? HTTPFetch.request(target.url("api/pairing/code"), token: token, body: JSONObject(), header: "X-Device-Token") as? JSONObject else { return result }
    return code
}
func pairingNewCode() throws -> JSONObject {
    if try PairingConnection(config: configuration()).token() == nil { _ = try pairingStart() }
    return try pairingManage("api/pairing/code", body: JSONObject())
}
func pairingManage(_ path: String, body: JSONObject? = nil) throws -> JSONObject {
    let target = try PairingConnection(config: configuration())
    guard let token = try target.token() else { throw ControlError("尚未连接公网配对服务") }
    guard let result = try HTTPFetch.request(target.url(path), token: token, body: body, timeout: 8, header: "X-Device-Token") as? JSONObject else { throw ControlError("配对服务返回无效数据") }
    return result
}
func pairingStatus() throws -> JSONObject {
    let target = try PairingConnection(config: configuration())
    guard let token = try target.token() else { return ["paired": false] }
    return try HTTPFetch.request(target.url("api/pairing/device"), token: token, header: "X-Device-Token") as? JSONObject ?? ["paired": false]
}
func publishDevice(_ path: String, _ body: JSONObject) throws -> JSONObject {
    let target = try PairingConnection(config: configuration())
    guard let token = try target.token() else { throw ControlError("本机尚未完成配对注册") }
    return try HTTPFetch.request(target.url(path), token: token, body: body, timeout: 5, limit: 600_000, header: "X-Device-Token") as? JSONObject ?? [:]
}
func cloudCommandAllowed(_ command: JSONObject) -> Bool {
    guard let id = command["screenId"] as? String, let config = try? configuration() else { return false }
    return CloudPermissions().allows(origin: publicAddress(config), id: id)
}

// 每个子进程都有超时和输出上限，退出异常不会把原始输出中的私人数据带到界面。
func execute(_ executable: String, _ args: [String], input: Data? = nil, timeout: Double = 10, limit: Int = 2_000_000) throws -> (Int32, Data) {
    let process = Process(), output = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
    process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = stdin
    try process.run()
    let timer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    defer { timer.cancel() }
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
    try stdin.fileHandleForWriting.close()
    var bytes = Data()
    while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
        if bytes.count + chunk.count > limit {
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw ControlError("子进程返回数据过大")
        }
        bytes.append(chunk)
    }
    process.waitUntilExit()
    return (process.terminationStatus, bytes)
}

final class SharedTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SharedTransport()
    private let lock = NSLock()
    private var requests = [Int: HTTPFetch]()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 30; config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func start(_ request: URLRequest, _ result: HTTPFetch) -> URLSessionDataTask {
        lock.lock(); defer { lock.unlock() }
        let task = session.dataTask(with: request); requests[task.taskIdentifier] = result; task.resume(); return task
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let result = requests[dataTask.taskIdentifier]; lock.unlock()
        guard let result else { dataTask.cancel(); return }
        if result.bytes.count + data.count > result.limit { result.failure = ControlError("响应超过限制"); dataTask.cancel() }
        else { result.bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let result = requests.removeValue(forKey: task.taskIdentifier); lock.unlock()
        result?.response = task.response as? HTTPURLResponse; result?.failure = result?.failure ?? error; result?.finished.signal()
    }
}

final class HTTPFetch: @unchecked Sendable {
    var bytes = Data(); var response: HTTPURLResponse?; var failure: Error?
    let finished = DispatchSemaphore(value: 0); let limit: Int
    init(limit: Int) { self.limit = limit }
    static func request(_ url: URL, token: String? = nil, body: Any? = nil, timeout: Double = 15, limit: Int = 2_000_000, header: String = "X-Display-Token") throws -> Any {
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        if let token { request.setValue(token, forHTTPHeaderField: header) }
        if let body { request.httpMethod = "POST"; request.httpBody = try jsonData(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        // 共用连接池保留 TLS 会话；超时取消，不自动重发播放指令。
        let delegate = HTTPFetch(limit: limit)
        let task = SharedTransport.shared.start(request, delegate)
        let timer = DispatchWorkItem { task.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        delegate.finished.wait()
        defer { timer.cancel() }
        guard delegate.failure == nil, let response = delegate.response else { throw ControlError("连接失败或超时") }
        guard response.statusCode == 200 else { throw ControlError(response.statusCode == 401 ? "访问口令无效" : "服务拒绝操作（\(response.statusCode)）") }
        return try JSONSerialization.jsonObject(with: delegate.bytes, options: .fragmentsAllowed)
    }
}

func managedKeys(_ body: Any? = nil, localStore: LocalKeys = LocalKeys()) throws -> Any {
    // Key 归属配对的 Mac，旧管理地址不能再将写入路由到服务器。
    if let body {
        guard let change = body as? JSONObject else { throw ControlError("Key 操作格式不正确") }
        return try localStore.change(change)
    }
    return try localStore.list()
}

func launch(_ args: [String], check: Bool = true) throws -> Data {
    let result = try execute("/bin/launchctl", args)
    if check && result.0 != 0 { throw ControlError("后台服务操作失败，请检查登录项权限") }
    return result.1
}
func serviceLoaded() -> Bool {
    (try? execute("/bin/launchctl", ["print", NativePaths.domain + "/" + NativePaths.label]).0) == 0
}
func installService(start: Bool) throws {
    let config = try configuration(), auto = config["musicLogin"] as? Bool ?? true
    try FileManager.default.createDirectory(at: NativePaths.agents, withIntermediateDirectories: true)
    let path = NativePaths.agents.appendingPathComponent(NativePaths.label + ".plist")
    // 看板须实时回应局域网请求；Background 会在系统繁忙时严重节流网络和文件操作。
    let plist: JSONObject = ["Label": NativePaths.label, "ProgramArguments": [NativePaths.service.path, "--serve"],
                             "RunAtLoad": auto, "KeepAlive": auto, "ThrottleInterval": 10, "ProcessType": "Interactive",
                             "StandardErrorPath": NativePaths.data.appendingPathComponent("service.log").path,
                             "StandardOutPath": NativePaths.data.appendingPathComponent("service.log").path]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path, options: .atomic)
    if start {
        if !serviceLoaded() {
            // bootout 返回后旧进程可能仍在退出，给 launchd 有界的清理时间。
            var loaded = false
            for _ in 0..<20 {
                if try execute("/bin/launchctl", ["bootstrap", NativePaths.domain, path.path]).0 == 0 { loaded = true; break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard loaded else { throw ControlError("后台服务启动失败，请稍后重试") }
        }
        // 已加载但已退出的服务也须启动；不带 -k，避免中断正在运行的音乐指令。
        _ = try launch(["kickstart", NativePaths.domain + "/" + NativePaths.label])
    }
}

// 只展示实际在线的 Wi-Fi/以太网 IPv4，过滤回环、VPN 与虚拟网桥。
func lanAddress(_ address: String, interface: String, type: String, active: Bool) -> JSONObject? {
    guard active, ["IEEE80211", "Ethernet"].contains(type) else { return nil }
    let parts = address.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
          parts[0] != 0, parts[0] != 127, parts[0] < 224,
          !(parts[0] == 169 && parts[1] == 254) else { return nil }
    return ["id": interface + ":" + address, "label": (type == "IEEE80211" ? "Wi-Fi" : "网线") + " · " + interface,
            "url": "http://\(address):18088"]
}
func lanAddresses() -> [JSONObject] {
    let hardware = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
    var types = [String: String]()
    for item in hardware {
        if let name = SCNetworkInterfaceGetBSDName(item), let type = SCNetworkInterfaceGetInterfaceType(item) {
            types[name as String] = type as String
        }
    }
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var cursor = head, result = [JSONObject]()
    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        let entry = item.pointee
        guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: entry.ifa_name)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let active = entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
        if let value = lanAddress(String(cString: host), interface: name, type: types[name] ?? "", active: active) { result.append(value) }
    }
    return result.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
}

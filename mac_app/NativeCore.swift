import Foundation
import Security
import CryptoKit
import Darwin

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
    static var domain: String { "gui/\(getuid())" }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        return ["url": "https://ipad.iamxg.com", "musicEnabled": true, "dashboardEnabled": true, "musicLogin": true]
    }
    return try readJSON(NativePaths.config)
}
func displayToken() throws -> String {
    guard let token = try Secrets.get("display-token") else { throw ControlError("请先导入原看板配置") }
    return token
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

func remoteKeys(_ body: Any? = nil, config: JSONObject? = nil, token: String? = nil) throws -> Any {
    let value = try config ?? configuration()
    let url = try endpoint(value["url"] as? String ?? "")
    let credential = try token ?? Secrets.get("management-token") ?? displayToken()
    return try HTTPFetch.request(url.appendingPathComponent("api/relay/keys"), token: credential, body: body)
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
    let plist: JSONObject = ["Label": NativePaths.label, "ProgramArguments": [NativePaths.service.path, "--serve"],
                             "RunAtLoad": auto, "KeepAlive": auto, "ThrottleInterval": 10, "ProcessType": "Background",
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

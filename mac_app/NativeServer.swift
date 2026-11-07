import Foundation
import Network
import Darwin

final class LocalKeys {
    let lock = NSLock()
    var cache: [String: (String, JSONObject)] = [:]
    let path: URL
    init(path: URL = NativePaths.data.appendingPathComponent("keys.json")) { self.path = path }
    var stationPath: URL { path.deletingLastPathComponent().appendingPathComponent("station.json") }
    static func stationURL(_ address: String) throws -> URL {
        var normalized = trimmed(address)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix("/v1") { normalized = String(normalized.dropLast(3)) }
        return try endpoint(normalized)
    }
    func station() throws -> JSONObject? {
        if FileManager.default.fileExists(atPath: stationPath.path) {
            let value = try readJSON(stationPath)
            guard value["type"] as? String == "sub2api", let address = value["url"] as? String else { throw ControlError("中转站配置不可读") }
            _ = try Self.stationURL(address)
            return value
        }
        // 旧版 Key 固定属于此站点，升级时保留归属，不能随新地址悄悄转发。
        return try records().isEmpty ? nil : ["type": "sub2api", "name": "Sub2API", "url": "https://sub2api.818tu.com"]
    }
    func saveStation(_ value: JSONObject) throws -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        let fd = open(path.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ControlError("无法锁定中转站配置") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ControlError("无法锁定中转站配置") }
        defer { _ = flock(fd, LOCK_UN) }
        guard value["type"] as? String == "sub2api", let name = value["name"] as? String,
              !trimmed(name).isEmpty, trimmed(name).count <= 60, let address = value["url"] as? String else { throw ControlError("中转站名称、类型或地址不正确") }
        let url = try Self.stationURL(address).absoluteString
        if let old = try station(), old["url"] as? String != url, try !records().isEmpty {
            guard value["confirmAddressChange"] as? Bool == true else { throw ControlError("修改地址会将已有 Key 用于新站点，请先确认") }
        }
        try writeJSON(["type": "sub2api", "name": trimmed(name), "url": url], stationPath)
        cache.removeAll()
        return ["ok": true]
    }
    func usageURL() throws -> URL {
        guard let station = try station(), let address = station["url"] as? String else { throw ControlError("请先添加中转站") }
        return try Self.stationURL(address).appendingPathComponent("v1/usage")
    }
    func records() throws -> [JSONObject] {
        if !FileManager.default.fileExists(atPath: path.path) { return [] }
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [JSONObject] else { throw ControlError("Key 配置不可读，拒绝覆盖") }
        return result
    }
    func list() throws -> [JSONObject] {
        lock.lock(); defer { lock.unlock() }
        return try records().map { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String, let key = try Secrets.get("company-" + id) else { throw ControlError("Key 配置不完整") }
            return ["id": id, "name": name, "maskedKey": key.count > 6 ? String(key.prefix(2)) + "****" + String(key.suffix(4)) : "****"]
        }
    }
    func change(_ value: JSONObject) throws -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        // 控制台请求与 HTTP 服务分属不同进程，文件锁避免并发写入覆盖其他 Key。
        let fd = open(path.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ControlError("无法锁定 Key 配置") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ControlError("无法锁定 Key 配置") }
        defer { _ = flock(fd, LOCK_UN) }
        var items = try records()
        let supplied = value["id"] as? String
        if value["id"] != nil && supplied == nil { throw ControlError("Key 标识不正确") }
        if let supplied, UUID(uuidString: supplied)?.uuidString.lowercased() != supplied { throw ControlError("Key 标识不正确") }
        let index = items.firstIndex { $0["id"] as? String == supplied }
        if let supplied, !supplied.isEmpty, index == nil { throw ControlError("Key 不存在") }
        if value["action"] as? String == "delete" {
            guard let index, let supplied else { throw ControlError("Key 不存在") }
            items.remove(at: index); try writeJSON(items, path)
            try Secrets.delete("company-" + supplied); cache.removeValue(forKey: supplied)
        } else if value["action"] as? String == "save" {
            guard try station() != nil else { throw ControlError("请先添加中转站，再配置 Key") }
            guard let rawName = value["name"] as? String, !trimmed(rawName).isEmpty, trimmed(rawName).count <= 60,
                  let key = value["key"] as? String, key.isEmpty || secretValid(key), index != nil || (!key.isEmpty && items.count < 50) else { throw ControlError("备注或 Key 不正确") }
            let id = supplied ?? UUID().uuidString.lowercased(), old = try Secrets.get("company-" + id)
            if !key.isEmpty { try Secrets.set("company-" + id, key) }
            let item: JSONObject = ["id": id, "name": trimmed(rawName)]
            if let index { items[index] = item } else { items.append(item) }
            do { try writeJSON(items, path) }
            catch { if let old { try? Secrets.set("company-" + id, old) } else { try? Secrets.delete("company-" + id) }; throw error }
            cache.removeValue(forKey: id)
        } else { throw ControlError("不支持的 Key 操作") }
        return ["ok": true]
    }
    func usage(_ id: String, force: Bool) throws -> JSONObject {
        let url = try usageURL()
        lock.lock()
        guard let items = try? records(), items.contains(where: { $0["id"] as? String == id }), let key = try? Secrets.get("company-" + id) else { lock.unlock(); throw ControlError("Key 不存在") }
        let cacheIdentity = url.absoluteString + "\n" + key
        if !force, let entry = cache[id], entry.0 == cacheIdentity, Date().timeIntervalSince1970 - (number(entry.1["updatedAt"]) ?? 0) < 60 { lock.unlock(); return entry.1 }
        lock.unlock()
        var result: JSONObject
        do {
            guard let data = try HTTPFetch.request(url, token: "Bearer " + key, timeout: 12, limit: 1_000_000, header: "Authorization") as? JSONObject,
                  data["isValid"] as? Bool == true else { throw ControlError("Key 无效") }
            let subscription = data["subscription"] as? JSONObject ?? [:]
            func amount(_ value: Any?) -> Any { if let value = number(value), abs(value) < 1e15 { return value }; return NSNull() }
            result = ["remaining": amount(data["remaining"]), "unit": ["USD", "CNY"].contains(data["unit"] as? String ?? "") ? data["unit"]! : "",
                      "dailyLimit": amount(subscription["daily_limit_usd"]), "dailyUsed": amount(subscription["daily_usage_usd"])]
        } catch { result = ["error": "查询失败，请检查 Key 或稍后重试"] }
        result["updatedAt"] = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        guard try usageURL() == url, (try Secrets.get("company-" + id)) == key, try records().contains(where: { $0["id"] as? String == id }) else { throw ControlError("Key 已变更") }
        cache[id] = (cacheIdentity, result); return result
    }
}

struct HTTPMessage {
    let method: String, path: String, headers: [String: String], body: Data
    static func parse(_ data: Data) throws -> HTTPMessage? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw ControlError("请求头过大") }; return nil
        }
        guard split.lowerBound <= 16384, let header = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw ControlError("请求头无效") }
        let lines = header.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[1].hasPrefix("/"), first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw ControlError("请求行无效") }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw ControlError("请求头无效") }
            let key = String(line[..<colon]).lowercased(), value = trimmed(String(line[line.index(after: colon)...]))
            guard headers[key] == nil else { throw ControlError("不允许重复请求头") }; headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { throw ControlError("不支持分块请求") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength), length <= 8192 else { throw ControlError("请求体过大") }
        let received = data.count - split.upperBound
        if received < length { return nil }
        guard received == length else { throw ControlError("不支持流水线请求") }
        return HTTPMessage(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(data[split.upperBound...]))
    }
}

final class LocalHTTPServer {
    let listener: NWListener, queue = DispatchQueue(label: "ipad.native.http")
    let handler: (HTTPMessage) -> (Int, String, Data)
    var peers = [ObjectIdentifier: NWConnection]()
    var running = false
    var failure: String?
    var isRunning: Bool { queue.sync { running } }
    var failed: Bool { queue.sync { failure != nil } }
    var errorDescription: String? { queue.sync { failure } }
    init(port: UInt16, host: String = "127.0.0.1", handler: @escaping (HTTPMessage) -> (Int, String, Data)) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        // 本地端点已同时限定地址和端口，不能再通过 on 重复指定，否则系统返回 EINVAL。
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { state in
            self.running = { if case .ready = state { return true }; return false }()
            // 端口刚从旧服务释放时可能先进入 waiting，不能永远等一个不会到来的网络变化。
            switch state {
            case .failed(let error), .waiting(let error): self.failure = "监听失败：\(error)"
            case .ready: self.failure = nil
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            guard self.peers.count < 64 else { connection.cancel(); return }
            let identity = ObjectIdentifier(connection); self.peers[identity] = connection
            connection.stateUpdateHandler = { state in if case .cancelled = state { self.peers.removeValue(forKey: identity) } }
            connection.start(queue: self.queue)
            let timeout = DispatchWorkItem { connection.cancel() }
            self.queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            self.receive(connection, Data(), timeout)
        }
        listener.start(queue: queue)
    }
    func stop() {
        let cancelled = DispatchSemaphore(value: 0)
        queue.sync {
            // 收到取消回调才表示端口真正释放，启停和测试均不能只等待 cancel 返回。
            self.listener.stateUpdateHandler = { state in
                if case .cancelled = state { cancelled.signal() }
            }
            self.listener.newConnectionHandler = nil
            self.listener.cancel()
            for peer in Array(self.peers.values) { peer.cancel() }
            self.running = false
        }
        _ = cancelled.wait(timeout: .now() + 2)
        queue.sync { self.listener.stateUpdateHandler = nil }
    }
    func receive(_ connection: NWConnection, _ previous: Data, _ timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { bytes, _, done, error in
            var data = previous; if let bytes { data.append(bytes) }
            do {
                if let request = try HTTPMessage.parse(data) {
                    DispatchQueue.global().async {
                        let result = self.handler(request)
                        let headers = "HTTP/1.1 \(result.0) \(result.0 == 200 ? "OK" : "Error")\r\nContent-Type: \(result.1); charset=utf-8\r\nContent-Length: \(result.2.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'\r\n\r\n"
                        connection.send(content: Data(headers.utf8) + result.2, completion: .contentProcessed { _ in timeout.cancel(); connection.cancel() })
                    }
                } else if error == nil && !done { self.receive(connection, data, timeout) }
                else { timeout.cancel(); connection.cancel() }
            } catch {
                connection.send(content: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in timeout.cancel(); connection.cancel() })
            }
        }
    }
}

final class NativeBackend {
    let lock = NSLock(), collector = CodexCollector(), music = NativeMusic(), keys = LocalKeys()
    let subscriptionLock = NSLock()
    let subscriptionRoot = URL(fileURLWithPath: "/path/to/subscription-bridge", isDirectory: true)
    var quota: JSONObject = ["plan": "未知", "primary": NSNull(), "secondary": NSNull(), "quotaAvailable": false]
    var conversations: JSONObject = ["conversationsAvailable": false, "conversations": [JSONObject]()]
    var server: LocalHTTPServer?
    var cloudPairing: JSONObject = ["paired": false]
    let token: String
    let localPairing: LocalPairing
    init(token: String? = nil, screens: LocalScreens = LocalScreens(path: NativePaths.data.appendingPathComponent("local-screens.json"))) throws {
        self.token = try token ?? displayToken()
        self.localPairing = LocalPairing(secret: self.token, screens: screens)
    }
    func status() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        var value = quota; value.merge(conversations) { _, new in new }
        value["state"] = "unknown"; value["schema"] = 1; value["servedAt"] = Date().timeIntervalSince1970
        return value
    }
    func publicKeys() -> [JSONObject] {
        (try? keys.list())?.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return ["id": id, "name": name, "usage": JSONObject()]
        } ?? []
    }
    func subscriptions() throws -> [JSONObject] {
        let script = subscriptionRoot.appendingPathComponent("manage.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw ControlError("Mac 上未找到订阅脚本") }
        let result = try execute("/usr/bin/python3", [script.path, "list"], timeout: 20)
        guard result.0 == 0, let text = String(data: result.1, encoding: .utf8) else { throw ControlError("无法读取订阅列表") }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["paoluz", "sc", "just"].contains(parts[0]) else { return nil }
            return ["id": parts[0], "remark": parts[1]]
        }
    }
    func updateSubscription(_ identity: String?) throws -> JSONObject {
        guard identity == nil || ["paoluz", "sc", "just"].contains(identity!) else { throw ControlError("订阅 ID 不正确") }
        guard subscriptionLock.try() else { throw ControlError("已有订阅更新正在进行") }
        defer { subscriptionLock.unlock() }
        let script = subscriptionRoot.appendingPathComponent("manage.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw ControlError("Mac 上未找到订阅脚本") }
        var args = [script.path, "sync"]
        if let identity { args += ["--id", identity] }
        let result = try execute("/usr/bin/python3", args, timeout: 300)
        guard result.0 == 0 else { throw ControlError("订阅更新失败，请检查 Surge 和订阅配置") }
        return ["ok": true]
    }
    func executeOpen(_ thread: String) throws -> Bool {
        let result = try execute("/usr/bin/open", ["-b", "com.openai.codex", "codex://threads/\(thread)?hostId=local"], timeout: 5)
        return result.0 == 0
    }
    func handle(_ request: HTTPMessage) -> (Int, String, Data) {
        func json(_ value: Any, _ code: Int = 200) -> (Int, String, Data) { (code, "application/json", (try? jsonData(value)) ?? Data("{}".utf8)) }
        let files = ["/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"), "/relay.js": ("relay.js", "text/javascript"), "/music.js": ("music.js", "text/javascript"), "/subscriptions.js": ("subscriptions.js", "text/javascript"), "/style.css": ("style.css", "text/css"), "/manifest.json": ("manifest.json", "application/manifest+json"), "/icon.svg": ("icon.svg", "image/svg+xml"), "/codex-icon.png": ("codex-icon.png", "image/png"), "/netease-music.png": ("netease-music.png", "image/png")]
        if request.method == "GET", let file = files[request.path], let data = try? Data(contentsOf: NativePaths.resources.appendingPathComponent("web/" + file.0)) { return (200, file.1, data) }
        guard request.path.hasPrefix("/api/") else { return json([:], 404) }
        if request.method == "GET", request.path == "/api/mode" { return json(["mode": "pairing"]) }
        if request.method == "POST", request.path == "/api/pairing/complete" {
            guard request.body.count <= 1024, let value = try? jsonObject(request.body),
                  let code = value["code"] as? String, code.count == 8 else { return json([:], 400) }
            let result = localPairing.complete(code, userAgent: request.headers["user-agent"] ?? "")
            return json(result.1, result.0)
        }
        let manager = secureEqual(request.headers["x-display-token"] ?? "", token)
        guard manager || localPairing.authorized(request.headers["x-pairing-token"] ?? "", userAgent: request.headers["user-agent"] ?? "") else { return json([:], 401) }
        do {
            let parts = URLComponents(string: "http://localhost" + request.path)
            let path = parts?.path ?? ""
            if request.method == "GET" {
                switch path {
                case "/api/status": return json(status())
                case "/api/subscriptions": return json(try subscriptions())
                case "/api/music": return json(music.snapshot())
                case "/api/relay/keys": return json(try keys.list())
                case "/api/relay/usage":
                    let id = parts?.queryItems?.first { $0.name == "id" }?.value ?? ""
                    return json(try keys.usage(id, force: parts?.queryItems?.contains { $0.name == "refresh" && $0.value == "1" } == true))
                default: return json([:], 404)
                }
            }
            let value = try jsonObject(request.body)
            switch path {
            case "/api/subscriptions/update": return json(try updateSubscription(value["id"] as? String))
            case "/api/relay/keys":
                // 在规范化路径后鉴权，查询参数不能绕过管理写入限制。
                guard manager else { return json([:], 403) }
                return json(try keys.change(value))
            case "/api/music/control":
                let result = music.control(value)
                return json(result, result["ok"] as? Bool == true ? 200 : 409)
            case "/api/open":
                guard let id = value["threadId"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id else { return json([:], 400) }
                let current = status(), items = current["conversations"] as? [JSONObject] ?? []
                guard items.contains(where: { $0["threadId"] as? String == id }) || (current["attention"] as? JSONObject)?["threadId"] as? String == id else { return json(["ok": false], 409) }
                let result = try execute("/usr/bin/open", ["-b", "com.openai.codex", "codex://threads/\(id)?hostId=local"], timeout: 5)
                return json(["ok": result.0 == 0], result.0 == 0 ? 200 : 503)
            default: return json([:], 404)
            }
        } catch { return json(["error": "操作失败，请检查输入或服务状态"], 400) }
    }
    func run() throws {
        music.setEnabled(try configuration()["musicEnabled"] as? Bool ?? true)
        var listenerError = ""
        // 公网不可用不能阻塞本地监听、采集和 App 状态刷新。
        Thread.detachNewThread {
            var pairing: JSONObject = ["paired": false]
            while true {
                do {
                    if pairing["paired"] as? Bool == true { pairing = try pairingStatus() }
                    else if (number(pairing["expiresAt"]) ?? 0) <= Date().timeIntervalSince1970 { pairing = try pairingStart() }
                    else {
                        let current = try pairingStatus()
                        if current["paired"] as? Bool == true { pairing = current }
                    }
                } catch { }
                self.lock.lock(); self.cloudPairing = pairing; self.lock.unlock()
                Thread.sleep(forTimeInterval: 10)
            }
        }
        Thread.detachNewThread { self.music.run() }
        Thread.detachNewThread { self.music.publish() }
        Thread.detachNewThread {
            while true {
                do {
                    var response = try publishDevice("api/device/exchange", ["status": self.status(), "keys": self.publicKeys()])
                    if let command = (response["commands"] as? [JSONObject])?.first,
                       let id = command["requestId"] as? String {
                        let ok: Bool
                        if command["kind"] as? String == "open", let thread = command["threadId"] as? String {
                            ok = (try? self.executeOpen(thread)) == true
                        } else if command["kind"] as? String == "subscriptions" {
                            ok = (try? self.updateSubscription(command["id"] as? String)) != nil
                        } else if command["kind"] as? String == "usage", let key = command["id"] as? String {
                            let usage = try? self.keys.usage(key, force: true)
                            ok = usage != nil
                            response = try publishDevice("api/device/exchange", ["status": self.status(), "keys": self.publicKeys(), "acks": [["requestId": id, "ok": ok, "usage": usage ?? JSONObject()] ]])
                            _ = response
                            Thread.sleep(forTimeInterval: 0.05)
                            continue
                        } else { ok = false }
                        response = try publishDevice("api/device/exchange", ["status": self.status(), "keys": self.publicKeys(), "acks": [["requestId": id, "ok": ok]]])
                        _ = response
                    }
                } catch { }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        Thread.detachNewThread {
            while true {
                let result = Result { try readQuota() }
                self.lock.lock()
                switch result {
                case .success(var value): value["quotaAvailable"] = true; value["cached"] = false; value["updatedAt"] = Date().timeIntervalSince1970; self.quota = value
                case .failure: self.quota["cached"] = self.quota["quotaAvailable"] as? Bool == true
                }
                self.lock.unlock(); Thread.sleep(forTimeInterval: 60)
            }
        }
        // 历史日志首次回放可能较慢，不能阻塞端口就绪与 App 状态心跳。
        Thread.detachNewThread {
            while true {
                let snapshot = autoreleasepool { self.collector.snapshot() }
                self.lock.lock(); self.conversations = snapshot; self.lock.unlock()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        while true {
            let config = try configuration()
            music.setEnabled(config["musicEnabled"] as? Bool ?? true)
            if server?.failed == true { listenerError = server?.errorDescription ?? ""; server?.stop(); server = nil }
            if config["dashboardEnabled"] as? Bool != false && server == nil {
                server = try LocalHTTPServer(port: 18088, host: "0.0.0.0", handler: handle); server?.start()
            } else if config["dashboardEnabled"] as? Bool == false && server != nil { server?.stop(); server = nil }
            if server?.isRunning == true { listenerError = "" }
            lock.lock(); let pairing = cloudPairing; lock.unlock()
            var runtime: JSONObject = ["dashboard": server?.isRunning == true ? "运行中" : "已停止或端口被占用", "listenerError": listenerError, "music": music.isEnabled() ? "运行中" : "已停止", "updatedAt": Date().timeIntervalSince1970]
            runtime["publicURL"] = publicAddress(config)
            runtime["localPairingCode"] = localPairing.current()
            runtime["paired"] = pairing["paired"] as? Bool ?? false
            runtime["pairingCode"] = pairing["code"] ?? NSNull()
            runtime["pairingExpiresAt"] = pairing["expiresAt"] ?? NSNull()
            try writeJSON(runtime, NativePaths.data.appendingPathComponent("runtime.json"))
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

import Foundation
import Darwin

func migrate(_ root: URL) throws -> JSONObject {
    guard !FileManager.default.fileExists(atPath: NativePaths.config.path) else { throw ControlError("已存在原生配置，拒绝覆盖；原文件均保留") }
    let token = trimmed(try String(contentsOf: root.appendingPathComponent(".display-token"), encoding: .utf8))
    try Secrets.set("display-token", token)
    var config = try configuration()
    let previous = root.appendingPathComponent(".mac-app.json")
    if FileManager.default.fileExists(atPath: previous.path) {
        let old = try readJSON(previous)
        if let url = old["url"] as? String { _ = try endpoint(url); config["url"] = url }
        if let token = old["token"] as? String, !token.isEmpty { try Secrets.set("management-token", token) }
    }
    let keys = root.appendingPathComponent(".relay-data/keys.json")
    if FileManager.default.fileExists(atPath: keys.path) {
        guard let records = try JSONSerialization.jsonObject(with: Data(contentsOf: keys)) as? [JSONObject] else { throw ControlError("原 Key 配置不可读") }
        var metadata = [JSONObject]()
        for item in records {
            guard let id = item["id"] as? String, let name = item["name"] as? String, let key = item["key"] as? String else { throw ControlError("原 Key 配置不完整") }
            try Secrets.set("company-" + id, key); metadata.append(["id": id, "name": name])
        }
        try writeJSON(metadata, NativePaths.data.appendingPathComponent("keys.json"))
    }
    let music = NativePaths.agents.appendingPathComponent("com.iamxg.ipad-music.plist")
    if let data = try? Data(contentsOf: music), let old = try PropertyListSerialization.propertyList(from: data, format: nil) as? JSONObject {
        config["musicLogin"] = old["RunAtLoad"] as? Bool ?? true
    }
    // 只读导入，不停止或删除旧服务；切换在新包验证后单独执行。
    try writeJSON(config, NativePaths.config)
    return ["ok": true, "message": "已迁移配置和钥匙串，原文件均保留"]
}

func nativeDispatch(_ value: JSONObject) throws -> JSONObject {
    var config = try configuration()
    let action = value["action"] as? String ?? ""
    if action == "status" {
        var status: JSONObject = ["url": config["url"] ?? "https://ipad.iamxg.com", "dashboard": "已停止", "music": "已停止", "musicLogin": config["musicLogin"] as? Bool ?? true,
                                  "appLogin": FileManager.default.fileExists(atPath: NativePaths.agents.appendingPathComponent("com.iamxg.ipad-control.plist").path)]
        if let runtime = try? readJSON(NativePaths.data.appendingPathComponent("runtime.json")), Date().timeIntervalSince1970 - (number(runtime["updatedAt"]) ?? 0) < 8, serviceLoaded() {
            status["dashboard"] = runtime["dashboard"]; status["music"] = runtime["music"]
            status["paired"] = runtime["paired"] as? Bool ?? false
            status["pairingCode"] = runtime["pairingCode"] ?? NSNull()
            status["pairingExpiresAt"] = runtime["pairingExpiresAt"] ?? NSNull()
        }
        status["lanAddresses"] = lanAddresses()
        return status
    }
    if action == "keys" { return ["keys": try remoteKeys()] }
    if action == "verify" {
        let token = try displayToken(), base = URL(string: "http://127.0.0.1:18088")!
        guard let snapshot = try HTTPFetch.request(base.appendingPathComponent("api/status"), token: token) as? JSONObject,
              snapshot["conversationsAvailable"] as? Bool == true else { throw ControlError("原生任务采集尚不可用") }
        let localKeys = try HTTPFetch.request(base.appendingPathComponent("api/relay/keys"), token: token) as? [JSONObject] ?? []
        let remote = try remoteKeys() as? [JSONObject] ?? []
        let music = try HTTPFetch.request(base.appendingPathComponent("api/music"), token: token) as? JSONObject ?? [:]
        let online = try HTTPFetch.request(URL(string: "https://ipad.iamxg.com/api/music")!, token: token) as? JSONObject ?? [:]
        _ = try media(["test"])
        return ["ok": true, "quotaAvailable": snapshot["quotaAvailable"] as? Bool ?? false,
                "taskCount": snapshot["conversationsTotal"] ?? 0, "localKeyCount": localKeys.count, "managedKeyCount": remote.count,
                "musicState": music["state"] ?? "unknown", "onlineMusicState": online["state"] ?? "unknown"]
    }
    if action == "connection-save" {
        guard let address = value["url"] as? String, let supplied = value["token"] as? String else { throw ControlError("连接设置不正确") }
        let url = try endpoint(address)
        let token = try supplied.isEmpty ? (Secrets.get("management-token") ?? displayToken()) : supplied
        guard secretValid(token) else { throw ControlError("口令格式不正确") }
        var candidate = config; candidate["url"] = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        _ = try remoteKeys(config: candidate, token: token)
        if !supplied.isEmpty { try Secrets.set("management-token", supplied) }
        try writeJSON(candidate, NativePaths.config)
    } else if ["key-save", "key-delete"].contains(action) {
        var body = value; body["action"] = action == "key-save" ? "save" : "delete"
        _ = try remoteKeys(body)
    } else if ["dashboard-start", "dashboard-stop", "music-start", "music-stop"].contains(action) {
        config[action.hasPrefix("dashboard") ? "dashboardEnabled" : "musicEnabled"] = action.hasSuffix("start")
        try writeJSON(config, NativePaths.config); try installService(start: true)
        // 等待服务下一轮读回设置，避免界面立即刷新时显示旧状态。
        Thread.sleep(forTimeInterval: 1.2)
    } else if action == "music-login" {
        guard let enabled = value["enabled"] as? Bool else { throw ControlError("登录启动设置不正确") }
        let previous = config, loaded = serviceLoaded()
        config["musicLogin"] = enabled; try writeJSON(config, NativePaths.config)
        do {
            _ = try launch(["bootout", NativePaths.domain + "/" + NativePaths.label], check: false)
            try installService(start: loaded)
        } catch {
            try writeJSON(previous, NativePaths.config); try? installService(start: loaded); throw error
        }
    } else if action == "app-login" {
        guard let enabled = value["enabled"] as? Bool else { throw ControlError("登录启动设置不正确") }
        let path = NativePaths.agents.appendingPathComponent("com.iamxg.ipad-control.plist")
        if enabled {
            try FileManager.default.createDirectory(at: NativePaths.agents, withIntermediateDirectories: true)
            let plist: JSONObject = ["Label": "com.iamxg.ipad-control", "ProgramArguments": [NativePaths.app.appendingPathComponent("Contents/MacOS/iPadControl").path], "RunAtLoad": true, "ProcessType": "Interactive"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path, options: .atomic)
        } else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    } else { throw ControlError("不支持的操作") }
    return ["ok": true]
}

@main struct NativeMain {
    static func main() {
        umask(0o077)
        do {
            try NativePaths.prepare()
            if CommandLine.arguments.contains("--serve") {
                // 文件锁防止启动两个实例，避免重复接收和执行音乐指令。
                let fd = open(NativePaths.data.appendingPathComponent("service.lock").path, O_CREAT | O_RDWR, 0o600)
                guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ControlError("后台服务已在运行") }
                defer { close(fd) }
                let backend = try NativeBackend()
                // macOS 网络与子进程回调需要主事件循环，采集循环不能占住主线程。
                DispatchQueue.global().async {
                    do { try backend.run() }
                    catch { fputs("原生后台运行失败，请检查配置与文件权限\n", stderr); exit(1) }
                }
                dispatchMain()
            } else {
                let result: JSONObject
                if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--migrate" {
                    result = try migrate(URL(fileURLWithPath: CommandLine.arguments[2]))
                } else {
                    let data = FileHandle.standardInput.readDataToEndOfFile()
                    guard data.count <= 8192 else { throw ControlError("请求过大") }
                    result = try nativeDispatch(jsonObject(data))
                }
                FileHandle.standardOutput.write(try jsonData(result)); FileHandle.standardOutput.write(Data([10]))
            }
        } catch {
            let message = (error as? ControlError)?.message ?? "本地操作失败，请检查文件权限和配置"
            if let data = try? jsonData(["error": message]) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
            exit(1)
        }
    }
}

import Foundation
import AppKit
import Darwin

// 配置只在 Mac 管理；网页仅能提交已配置项目的 ID，不能传入路径或命令。
final class ConsoleActions {
    static let subscriptionLock = NSLock()
    let path: URL
    private let lock = NSLock()
    private var running: String?
    private var results = [String: String]()
    private let appName: (String) -> String
    init(path: URL = NativePaths.data.appendingPathComponent("console-actions.json"), appName: @escaping (String) -> String = appDisplayName) {
        self.path = path; self.appName = appName
    }

    private func access<T>(_ action: (inout [JSONObject]) throws -> T) throws -> T {
        let fd = open(path.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ControlError("无法读取控制台配置") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ControlError("无法锁定控制台配置") }
        defer { _ = flock(fd, LOCK_UN) }
        var records = [JSONObject]()
        if FileManager.default.fileExists(atPath: path.path) {
            guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [JSONObject] else { throw ControlError("控制台配置损坏，拒绝覆盖") }
            records = saved
        }
        let before = records
        let value = try action(&records)
        if !NSArray(array: before).isEqual(to: records) { try writeJSON(records, path) }
        return value
    }
    func list() throws -> [JSONObject] {
        try access { records in
            // 旧记录未标注名称来源，只迁移与旧默认文件名完全相同的名称，保留自定义名称。
            for index in records.indices where records[index]["kind"] as? String == "app" {
                guard let target = records[index]["target"] as? String,
                      FileManager.default.fileExists(atPath: target),
                      records[index]["name"] as? String == URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent else { continue }
                let name = appName(target)
                if !name.isEmpty && name.count <= 60 { records[index]["name"] = name }
            }
            // 旧版 32 像素缓存只升级一次，保留配置和顺序；版本标记不随快照上传。
            for index in records.indices where records[index]["kind"] as? String == "app" && (records[index]["icon"] == nil || records[index]["iconPixels"] as? Int != 96) {
                records[index]["icon"] = Self.icon(records[index]["target"] as? String ?? "")
                records[index]["iconPixels"] = 96
            }
            return records
        }
    }
    static func icon(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        // 网页显示 48 CSS 像素，按 iPad 的 2 倍像素从系统原图绘制，避免放大缩略图。
        let source = NSWorkspace.shared.icon(forFile: path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return "" }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 40000 else { return "" }
        return "data:image/png;base64," + data.base64EncodedString()
    }
    func move(_ id: String, to targetID: String) throws {
        try access { records in
            guard let index = records.firstIndex(where: { $0["id"] as? String == id }),
                  let target = records.firstIndex(where: { $0["id"] as? String == targetID }) else { throw ControlError("项目已删除，请刷新") }
            let kind = records[index]["kind"] as? String
            guard kind == records[target]["kind"] as? String else { throw ControlError("只能在同类型内排序") }
            let group = records.indices.filter { records[$0]["kind"] as? String == kind }
            var items = group.map { records[$0] }
            let item = items.remove(at: group.firstIndex(of: index)!)
            // 向上落在目标前，向下落在目标后；其他类型保留原槽位和内容。
            items.insert(item, at: group.firstIndex(of: target)!)
            for (slot, value) in zip(group, items) { records[slot] = value }
        }
    }

    func save(_ value: JSONObject) throws -> JSONObject {
        guard let name = value["name"] as? String, !trimmed(name).isEmpty, trimmed(name).count <= 60,
              let kind = value["kind"] as? String, ["app", "script", "command", "subscription"].contains(kind),
              let target = value["target"] as? String, !trimmed(target).isEmpty, target.utf8.count <= 4096, !target.contains("\0") else { throw ControlError("请填写名称及有效的应用、脚本或命令") }
        let shell = value["shell"] as? String ?? (kind == "subscription" ? "/usr/bin/python3" : "/bin/zsh")
        if kind != "subscription", !["/bin/zsh", "/bin/bash"].contains(shell) { throw ControlError("请选择 zsh 或 bash") }
        let id = value["id"] as? String ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: id) != nil else { throw ControlError("项目标识不正确") }
        var item: JSONObject = ["id": id, "name": trimmed(name), "kind": kind, "target": target, "shell": shell]
        if kind == "subscription" { item["subscriptionScript"] = value["subscriptionScript"] as? String ?? "" }
        try validateTarget(item)
        if kind == "app" { item["icon"] = Self.icon(target); item["iconPixels"] = 96 }
        return try access { records in
            // 成功时间属于脚本和订阅范围；旧记录补齐脚本时保留原项目时间，不接受界面覆盖。
            if kind == "subscription", let previous = records.first(where: {
                $0["kind"] as? String == kind && $0["target"] as? String == target && $0["lastUpdatedAt"] != nil &&
                    (($0["subscriptionScript"] as? String == item["subscriptionScript"] as? String && $0["shell"] as? String == shell) ||
                     ($0["id"] as? String == id && $0["subscriptionScript"] == nil))
            }) {
                item["lastUpdatedAt"] = previous["lastUpdatedAt"]
            }
            if value["id"] != nil {
                guard let index = records.firstIndex(where: { $0["id"] as? String == id }) else { throw ControlError("项目已删除，请刷新") }
                records[index] = item
            } else {
                guard records.count < 50 else { throw ControlError("最多添加 50 个快捷项目") }
                records.append(item)
            }
            return ["ok": true, "id": id]
        }
    }
    func delete(_ id: String) throws {
        try access { records in
            guard let index = records.firstIndex(where: { $0["id"] as? String == id }) else { throw ControlError("项目已删除，请刷新") }
            records.remove(at: index)
        }
    }
    private func validateTarget(_ item: JSONObject) throws {
        guard let kind = item["kind"] as? String, let target = item["target"] as? String else { throw ControlError("项目配置不完整") }
        if kind == "subscription" {
            guard Self.validSubscriptionID(target) else { throw ControlError("订阅 ID 仅支持 1–80 位字母、数字、点、下划线或连字符，且以字母或数字开头") }
            guard let script = item["subscriptionScript"] as? String, script.hasPrefix("/"), script.utf8.count <= 4096, !script.contains("\0"),
                  let interpreter = item["shell"] as? String, interpreter.hasPrefix("/"), interpreter.utf8.count <= 4096, !interpreter.contains("\0") else { throw ControlError("请配置订阅脚本及解释器的绝对路径") }
            var scriptDirectory: ObjCBool = false, interpreterDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: script, isDirectory: &scriptDirectory), !scriptDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: script) else { throw ControlError("订阅脚本不存在或不可读取") }
            guard FileManager.default.fileExists(atPath: interpreter, isDirectory: &interpreterDirectory), !interpreterDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: interpreter) else { throw ControlError("订阅解释器不存在或不可执行") }
            return
        }
        if kind == "command" { return }
        var directory: ObjCBool = false
        guard target.hasPrefix("/"), FileManager.default.fileExists(atPath: target, isDirectory: &directory) else { throw ControlError("所选文件已移动或不存在") }
        if kind == "app" {
            guard directory.boolValue, target.hasSuffix(".app"), Bundle(path: target)?.executableURL != nil else { throw ControlError("请选择有效的 .app 应用") }
        } else {
            guard kind == "script", !directory.boolValue, FileManager.default.isReadableFile(atPath: target) else { throw ControlError("请选择可读取的 Shell 脚本文件") }
        }
    }
    func snapshot() throws -> [JSONObject] {
        let records = try list()
        lock.lock(); defer { lock.unlock() }
        return records.map { item in
            let id = item["id"] as? String ?? ""
            var snapshot: JSONObject = ["id": id, "name": item["name"] ?? "", "kind": item["kind"] ?? "", "icon": item["icon"] ?? "", "state": running == id ? "running" : results[id] ?? "idle"]
            if item["kind"] as? String == "subscription", let updatedAt = number(item["lastUpdatedAt"]), updatedAt.isFinite, updatedAt > 0, updatedAt <= 253402300799 {
                snapshot["lastUpdatedAt"] = updatedAt
            }
            return snapshot
        }
    }
    static func validSubscriptionID(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z"#, options: .regularExpression) != nil
    }
    func recordSubscriptionSuccess(_ item: JSONObject, at timestamp: TimeInterval = Date().timeIntervalSince1970) throws {
        guard let target = item["target"] as? String, Self.validSubscriptionID(target),
              let script = item["subscriptionScript"] as? String, !script.isEmpty, let interpreter = item["shell"] as? String,
              timestamp.isFinite, timestamp > 0, timestamp <= 253402300799 else { throw ControlError("订阅更新时间无效") }
        try access { records in
            // 仅同步同一脚本/解释器的范围，避免多个订阅来源互相覆盖更新时间。
            for index in records.indices where records[index]["kind"] as? String == "subscription" &&
                records[index]["subscriptionScript"] as? String == script && records[index]["shell"] as? String == interpreter &&
                (target == "all" || records[index]["target"] as? String == target) {
                records[index]["lastUpdatedAt"] = timestamp
            }
        }
    }
    func start(_ value: JSONObject) throws -> JSONObject {
        guard Set(value.keys) == ["id"], let id = value["id"] as? String, UUID(uuidString: id) != nil else { throw ControlError("执行请求只能包含项目 ID") }
        lock.lock()
        guard running == nil else { lock.unlock(); throw ControlError("已有快捷项目正在执行") }
        do {
            guard let item = try list().first(where: { $0["id"] as? String == id }) else { throw ControlError("项目已删除，请刷新") }
            try validateTarget(item)
            running = id
            lock.unlock()
            DispatchQueue.global().async {
                let state: String
                do { state = try self.run(item) == 0 ? "succeeded" : "failed" }
                catch { state = "failed" }
                self.lock.lock(); self.results[id] = state; self.running = nil; self.lock.unlock()
            }
            return ["ok": true]
        } catch { lock.unlock(); throw error }
    }
    private func run(_ item: JSONObject) throws -> Int32 {
        let process = Process(), kind = item["kind"] as! String, target = item["target"] as! String
        if kind == "subscription", !Self.subscriptionLock.try() { throw ControlError("已有订阅更新正在进行") }
        defer { if kind == "subscription" { Self.subscriptionLock.unlock() } }
        if kind == "subscription" {
            let script = item["subscriptionScript"] as! String
            process.executableURL = URL(fileURLWithPath: item["shell"] as! String)
            // 参数单独传递，订阅 ID 不能成为解释器选项或 Shell 命令。
            process.arguments = [script, "sync"] + (target == "all" ? [] : ["--id", target])
            process.currentDirectoryURL = URL(fileURLWithPath: script).deletingLastPathComponent()
        } else if kind == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-a", target]
        } else {
            guard let shell = item["shell"] as? String, ["/bin/zsh", "/bin/bash"].contains(shell) else { throw ControlError("脚本解释器不正确") }
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = kind == "command" ? ["-c", target] : [target]
        }
        if kind != "subscription" {
            process.currentDirectoryURL = kind == "script" ? URL(fileURLWithPath: target).deletingLastPathComponent() : FileManager.default.homeDirectoryForCurrentUser
        }
        // 后台任务不等待终端输入、不回传可能含密钥的输出；常用工具路径显式提供给 launchd 环境。
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        // shortcut: 超时终止直接进程，脚本自行启动的后台任务不托管；需要作业管理时再增加进程组取消。
        let timer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timer)
        defer { timer.cancel() }
        process.waitUntilExit()
        if kind == "subscription", process.terminationStatus == 0 { try recordSubscriptionSuccess(item) }
        return process.terminationStatus
    }
}

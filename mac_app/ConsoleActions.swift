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
    init(path: URL = NativePaths.data.appendingPathComponent("console-actions.json")) { self.path = path }

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
        let shell = value["shell"] as? String ?? "/bin/zsh"
        guard ["/bin/zsh", "/bin/bash"].contains(shell) else { throw ControlError("请选择 zsh 或 bash") }
        let id = value["id"] as? String ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: id) != nil else { throw ControlError("项目标识不正确") }
        var item: JSONObject = ["id": id, "name": trimmed(name), "kind": kind, "target": target, "shell": shell]
        try validateTarget(item)
        if kind == "app" { item["icon"] = Self.icon(target); item["iconPixels"] = 96 }
        return try access { records in
            // 时间属于订阅范围，改名保留、换范围采用新范围记录；不接受界面传入的时间。
            if kind == "subscription", let previous = records.first(where: { $0["kind"] as? String == kind && $0["target"] as? String == target && $0["lastUpdatedAt"] != nil }) {
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
            guard ["all", "paoluz", "sc", "just"].contains(target) else { throw ControlError("请选择有效的订阅范围") }
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
    func recordSubscriptionSuccess(_ identity: String?, at timestamp: TimeInterval = Date().timeIntervalSince1970) throws {
        guard identity == nil || ["paoluz", "sc", "just"].contains(identity!), timestamp.isFinite, timestamp > 0, timestamp <= 253402300799 else { throw ControlError("订阅更新时间无效") }
        try access { records in
            // 仅在脚本成功后调用；全部更新覆盖各订阅，单项更新不改变“更新全部”的时间。
            for index in records.indices where records[index]["kind"] as? String == "subscription" && (identity == nil || records[index]["target"] as? String == identity) {
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
    // 新旧入口共用互斥锁及原脚本，保留校验和失败回滚。
    static func updateSubscription(_ identity: String?) throws -> JSONObject {
        guard identity == nil || ["paoluz", "sc", "just"].contains(identity!) else { throw ControlError("订阅 ID 不正确") }
        guard subscriptionLock.try() else { throw ControlError("已有订阅更新正在进行") }
        defer { subscriptionLock.unlock() }
        let script = URL(fileURLWithPath: "/path/to/subscription-bridge/manage.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw ControlError("Mac 上未找到订阅脚本") }
        var args = [script.path, "sync"]
        if let identity { args += ["--id", identity] }
        let result = try execute("/usr/bin/python3", args, timeout: 300)
        guard result.0 == 0 else { throw ControlError("订阅更新失败，请检查 Surge 和订阅配置") }
        try ConsoleActions().recordSubscriptionSuccess(identity)
        return ["ok": true]
    }
    private func run(_ item: JSONObject) throws -> Int32 {
        let process = Process(), kind = item["kind"] as! String, target = item["target"] as! String
        if kind == "subscription" {
            _ = try Self.updateSubscription(target == "all" ? nil : target)
            return 0
        }
        if kind == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-a", target]
        } else {
            guard let shell = item["shell"] as? String, ["/bin/zsh", "/bin/bash"].contains(shell) else { throw ControlError("脚本解释器不正确") }
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = kind == "command" ? ["-c", target] : [target]
        }
        process.currentDirectoryURL = kind == "script" ? URL(fileURLWithPath: target).deletingLastPathComponent() : FileManager.default.homeDirectoryForCurrentUser
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
        return process.terminationStatus
    }
}

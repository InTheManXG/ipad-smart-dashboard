import Foundation
import Darwin

// 配置只在 Mac 管理；网页仅能提交已配置项目的 ID，不能传入路径或命令。
final class ConsoleActions {
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
    func list() throws -> [JSONObject] { try access { $0 } }

    func save(_ value: JSONObject) throws -> JSONObject {
        guard let name = value["name"] as? String, !trimmed(name).isEmpty, trimmed(name).count <= 60,
              let kind = value["kind"] as? String, ["app", "script", "command"].contains(kind),
              let target = value["target"] as? String, !trimmed(target).isEmpty, target.utf8.count <= 4096, !target.contains("\0") else { throw ControlError("请填写名称及有效的应用、脚本或命令") }
        let shell = value["shell"] as? String ?? "/bin/zsh"
        guard ["/bin/zsh", "/bin/bash"].contains(shell) else { throw ControlError("请选择 zsh 或 bash") }
        let id = value["id"] as? String ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: id) != nil else { throw ControlError("项目标识不正确") }
        let item: JSONObject = ["id": id, "name": trimmed(name), "kind": kind, "target": target, "shell": shell]
        try validateTarget(item)
        return try access { records in
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
            return ["id": id, "name": item["name"] ?? "", "kind": item["kind"] ?? "", "state": running == id ? "running" : results[id] ?? "idle"]
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

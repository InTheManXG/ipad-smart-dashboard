import Foundation
import AppKit
import SQLite3
import Darwin

final class TurnReader {
    var state = "unknown", active = false, started: Double?
    var pending = Set<String>()
    var offset: UInt64 = 0, inode: UInt64 = 0
    var partial = Data(), skipping = false, caughtUp = false
    func consume(_ event: JSONObject) {
        guard let payload = event["payload"] as? JSONObject else { return }
        let type = event["type"] as? String ?? "", kind = payload["type"] as? String ?? ""
        if type == "turn_context" || (type == "response_item" && ["reasoning", "function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output"].contains(kind)) { state = "running" }
        if type == "event_msg" {
            switch kind {
            case "task_started":
                state = "running"; active = true; pending.removeAll()
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let stamp = event["timestamp"] as? String ?? ""
                started = formatter.date(from: stamp)?.timeIntervalSince1970
                if started == nil { formatter.formatOptions = [.withInternetDateTime]; started = formatter.date(from: stamp)?.timeIntervalSince1970 }
            case "task_complete":
                // 回合终止后，旧异步提问不再需要用户处理，不能覆盖完成或错误状态。
                active = false; pending.removeAll()
                state = payload["is_error"] as? Bool == true || (payload["error"] != nil && !(payload["error"] is NSNull)) ? "error" : "done"
            case "turn_aborted": active = false; state = "unknown"; pending.removeAll()
            case "error": active = false; pending.removeAll(); state = "error"
            case "item_completed": if (payload["item"] as? JSONObject)?["type"] as? String == "UserMessage" { pending.removeAll() }
            default: break
            }
        }
        guard type == "response_item" else { return }
        if kind == "message" && payload["role"] as? String == "user" { pending.removeAll() }
        let name = (payload["name"] as? String ?? "").split(separator: ".").last.map(String.init) ?? ""
        let id = payload["call_id"] as? String ?? ""
        if ["function_call", "custom_tool_call"].contains(kind) && ["request_user_input", "request_user_input_async"].contains(name) { pending.insert(id) }
        if ["function_call_output", "custom_tool_call_output"].contains(kind),
           (payload["output"] as? String ?? "").contains("\"answers\"") { pending.remove(id) }
    }
    func read(_ path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let nextInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if inode != nextInode || size < offset {
            state = "unknown"; active = false; started = nil; pending.removeAll(); partial.removeAll(); skipping = false; offset = 0; caughtUp = false
            inode = nextInode
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seek(toOffset: offset)
        // 首次回放分批完成；未追上文件末尾前不把旧事件冒充当前状态。
        var budget = 4_194_304
        while budget > 0, let chunk = try file.read(upToCount: min(65536, budget)), !chunk.isEmpty {
            offset += UInt64(chunk.count); budget -= chunk.count
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let newline = chunk[cursor...].firstIndex(of: 10), end = newline ?? chunk.endIndex
                if !skipping {
                    if partial.count + end - cursor > 1_048_576 { partial.removeAll(keepingCapacity: true); skipping = true }
                    else { partial.append(chunk[cursor..<end]) }
                }
                if newline != nil {
                    if !skipping, let event = try? jsonObject(partial) { consume(event) }
                    partial.removeAll(keepingCapacity: true); skipping = false
                }
                cursor = newline.map { $0 + 1 } ?? chunk.endIndex
            }
        }
        caughtUp = offset >= size
        if !caughtUp { return "unknown" }
        if !pending.isEmpty { return "waiting" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if state == "running" && !active && Date().timeIntervalSince1970 - modified > 120 { return "unknown" }
        return state
    }
}

final class CodexCollector {
    let home: URL
    let orderFile: URL?
    private var orderNeedsSave = false
    private lazy var order: [String] = {
        // 顺序缓存只保存 ID；损坏时重建，不让展示偏好阻断任务采集。
        guard let orderFile, let saved = try? readJSON(orderFile), let ids = saved["threadIds"] as? [String],
              ids.count <= 64, Set(ids).count == ids.count,
              ids.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) else { return [] }
        return ids
    }()
    var readers: [String: (String, TurnReader)] = [:]
    init(home: URL = NativePaths.home.appendingPathComponent(".codex"), orderFile: URL? = NativePaths.data.appendingPathComponent("task-order.json")) {
        self.home = home; self.orderFile = orderFile
    }
    func unread() throws -> Set<String> {
        let data = try readJSON(home.appendingPathComponent(".codex-global-state.json"))
        guard let state = data["electron-thread-read-state-v1"] as? JSONObject, state["version"] as? Int == 1,
              let identities = state["unreadByIdentity"] as? JSONObject else { throw ControlError("桌面未读状态不可用") }
        var unread = Set<String>()
        // 本地任务库由账号共用，合并各账号的本地未读标记，避免切换账号后整表失效。
        for identity in identities.values {
            guard let scopes = identity as? JSONObject else { throw ControlError("桌面未读状态不可用") }
            for (scope, value) in scopes where scope.hasPrefix("local:") {
                guard let ids = value as? [String], ids.allSatisfy({ !$0.isEmpty }) else { throw ControlError("本地未读状态不可用") }
                unread.formUnion(ids)
            }
        }
        return unread
    }
    func snapshot() -> JSONObject {
        do {
            let unseen = try unread()
            var database: OpaquePointer?, statement: OpaquePointer?
            guard sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if database != nil { sqlite3_close(database) }; throw ControlError("无法读取 Codex 数据库")
            }
            defer { sqlite3_finalize(statement); sqlite3_close(database) }
            sqlite3_busy_timeout(database, 1000)
            let included = Array(unseen.union(order))
            let placeholders = included.isEmpty ? "NULL" : Array(repeating: "?", count: included.count).joined(separator: ",")
            let queued = order.isEmpty ? "NULL" : Array(repeating: "?", count: order.count).joined(separator: ",")
            // 已排队任务优先进入候选集，避免新消息把它挤出 64 项上限或 24 小时窗口。
            let sql = "SELECT id, rollout_path, COALESCE(NULLIF(name, ''), title), updated_at FROM threads WHERE archived = 0 AND source IN ('cli','vscode','exec','appServer') AND (updated_at >= ? OR id IN (\(placeholders))) ORDER BY CASE WHEN id IN (\(queued)) THEN 0 ELSE 1 END, updated_at DESC, id ASC LIMIT 64"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ControlError("Codex 数据结构已变化") }
            sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970) - 86400)
            for (index, id) in (included + order).enumerated() {
                sqlite3_bind_text(statement, Int32(index + 2), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            var items = [JSONObject](), keep = Set<String>(), unresolved = Set<String>()
            var attention: JSONObject?, attentionUpdatedAt: Int64 = .min
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let path = String(cString: sqlite3_column_text(statement, 1))
                let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "未命名对话"
                keep.insert(id)
                if readers[id]?.0 != path { readers[id] = (path, TurnReader()) }
                let reader = readers[id]!.1
                let state: String
                do {
                    state = try reader.read(path)
                    if !reader.caughtUp { unresolved.insert(id) }
                } catch { state = "unknown"; unresolved.insert(id) }
                if ["running", "waiting", "error", "done"].contains(state) && (state != "done" || unseen.contains(id)) {
                    var titleBytes = Array(title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").utf8.prefix(80))
                    while String(bytes: titleBytes, encoding: .utf8) == nil && !titleBytes.isEmpty { titleBytes.removeLast() }
                    var item: JSONObject = ["title": String(bytes: titleBytes, encoding: .utf8) ?? "", "state": state]
                    if UUID(uuidString: id)?.uuidString.lowercased() == id { item["threadId"] = id }
                    if unseen.contains(id) { item["unread"] = true }
                    if state == "running", reader.active, let start = reader.started { item["elapsedSeconds"] = max(0, Int(Date().timeIntervalSince1970 - start)) }
                    // 固定列表顺序不改变提醒规则，仍优先展示最近更新的待处理对话。
                    let updatedAt = sqlite3_column_int64(statement, 3)
                    if state == "waiting", item["threadId"] != nil, updatedAt > attentionUpdatedAt {
                        attention = ["threadId": id, "title": item["title"]!]; attentionUpdatedAt = updatedAt
                    }
                    items.append(item)
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw ControlError("读取 Codex 任务失败") }
            readers = readers.filter { keep.contains($0.key) }
            let activeIDs = items.compactMap { $0["threadId"] as? String }
            var nextOrder = order.filter { activeIDs.contains($0) || unresolved.contains($0) }
            for id in activeIDs where !nextOrder.contains(id) { nextOrder.append(id) }
            if nextOrder != order {
                order = nextOrder; orderNeedsSave = true
            }
            // 仅队列改变或上次保存失败时写盘；暂时读不到日志不清除位置。
            if orderNeedsSave, let orderFile, (try? writeJSON(["threadIds": order], orderFile)) != nil {
                orderNeedsSave = false
            }
            let byID = Dictionary(uniqueKeysWithValues: items.compactMap { item in (item["threadId"] as? String).map { ($0, item) } })
            items = order.compactMap { byID[$0] } + items.filter { $0["threadId"] == nil }
            return ["conversationsAvailable": true, "conversationsTotal": items.count, "conversations": Array(items.prefix(8)), "attention": attention as Any? ?? NSNull()]
        } catch { return ["conversationsAvailable": false, "conversationsTotal": 0, "conversations": [JSONObject]()] }
    }
}

func codexBinary() throws -> URL {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { throw ControlError("未找到 Codex App") }
    for path in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"] {
        let url = app.appendingPathComponent(path)
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw ControlError("Codex App 未提供可用的 CLI")
}

func readQuota() throws -> JSONObject {
    let process = Process(), input = Pipe(), output = Pipe()
    // 额度查询也运行在常驻线程；成功、启动失败和超时都要释放管道。
    defer {
        try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    }
    process.executableURL = try codexBinary(); process.arguments = ["app-server", "--listen", "stdio://"]
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    let timer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        let reap = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: reap)
        process.waitUntilExit(); reap.cancel(); timer.cancel()
    }
    var buffer = Data()
    func send(_ value: JSONObject) throws { var data = try jsonData(value); data.append(10); try input.fileHandleForWriting.write(contentsOf: data) }
    func reply(_ id: Int) throws -> JSONObject {
        while true {
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                guard let message = try? jsonObject(Data(line)), message["id"] as? Int == id else { continue }
                guard let result = message["result"] as? JSONObject else { throw ControlError("Codex 额度接口返回错误") }
                return result
            }
            // 管道协议必须立即消费短消息，不能等缓冲区填满或等待服务退出。
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { throw ControlError("Codex 额度读取超时") }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.count > 1_048_576 { throw ControlError("Codex 响应过大") }
        }
    }
    try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ipad_native_dashboard", "version": "2.0"]]])
    _ = try reply(1); try send(["method": "initialized", "params": JSONObject()])
    try send(["id": 2, "method": "account/rateLimits/read", "params": JSONObject()])
    let response = try reply(2)
    guard let limits = (response["rateLimitsByLimitId"] as? JSONObject)?["codex"] as? JSONObject ?? response["rateLimits"] as? JSONObject else { throw ControlError("额度数据不可用") }
    var result: JSONObject = ["plan": String((limits["planType"] as? String ?? "未知").prefix(19))]
    for key in ["primary", "secondary"] {
        guard let window = limits[key] as? JSONObject, let used = number(window["usedPercent"]),
              let minutes = number(window["windowDurationMins"]), let reset = number(window["resetsAt"]), minutes >= 0, reset >= 0 else { result[key] = NSNull(); continue }
        result[key] = ["usedPercent": max(0, min(100, used)), "windowDurationMins": minutes, "resetsAt": reset]
    }
    return result
}

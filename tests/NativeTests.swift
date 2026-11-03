import Foundation
import SQLite3

@main struct NativeTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ControlError("验证失败：" + message) }; checks += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try check(rejected, message)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/native-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try check(secureEqual("abc", "abc") && !secureEqual("abc", "abcd"), "认证比较")
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com/x", "https://example.com?key=x", "file:///tmp", "https://example.com:65536"] {
            try rejects("拒绝不安全地址") { _ = try endpoint(address) }
        }
        try check(try endpoint("http://127.0.0.1:18088").port == 18088, "本机地址可用")
        try check(number(true) == nil && number(Double.infinity) == nil && number(1) == 1, "数字边界")
        let lines = parseLyrics("[offset:1000]\n[00:02.50][00:04.000]你好\n[00:05.00]\n[00:04.0]世界")
        try check(lines.count == 3 && number(lines[0]["time"]) == 1.5 && lines[1]["text"] as? String == "你好 / 世界" && lines[2]["text"] as? String == "", "歌词多时间标签与间奏、偏移")
        try check(normalizeSong("Ａ B_Ｃ！") == "abc", "兼容字符规范化")
        for text in ["GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx", "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n", "GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n"] {
            try rejects("拒绝歧义 HTTP 请求") { _ = try HTTPMessage.parse(Data(text.utf8)) }
        }
        try check(try HTTPMessage.parse(Data("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx".utf8)) == nil, "等待完整请求体")
        let parsed = try HTTPMessage.parse(Data("POST /api/test HTTP/1.1\r\nContent-Length: 2\r\nX-Display-Token: test\r\n\r\n{}".utf8))!
        try check(parsed.headers["x-display-token"] == "test" && parsed.body == Data("{}".utf8), "HTTP 字段规范化")

        let path = root.appendingPathComponent("turn.jsonl"), reader = TurnReader()
        FileManager.default.createFile(atPath: path.path, contents: Data())
        func append(_ type: String, _ payload: JSONObject, stamp: String = "2026-11-03T00:00:00.000Z") throws {
            let file = try FileHandle(forWritingTo: path); defer { try? file.close() }; try file.seekToEnd()
            var data = try jsonData(["type": type, "payload": payload, "timestamp": stamp]); data.append(10); try file.write(contentsOf: data)
        }
        try append("event_msg", ["type": "task_started"])
        try check(try reader.read(path.path) == "running" && reader.active && reader.started != nil, "真实开始与计时")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -180)], ofItemAtPath: path.path)
        try check(try reader.read(path.path) == "running", "静默超过三分钟仍运行")
        try append("response_item", ["type": "function_call", "name": "functions.request_user_input_async", "call_id": "ask"])
        try check(try reader.read(path.path) == "waiting", "等待用户回答")
        try append("response_item", ["type": "function_call_output", "call_id": "ask", "output": "accepted"])
        try check(try reader.read(path.path) == "waiting", "异步提问受理不是回答")
        try append("response_item", ["type": "message", "role": "user"])
        try check(try reader.read(path.path) == "running", "回答后恢复运行")
        try append("event_msg", ["type": "task_complete"])
        try check(try reader.read(path.path) == "done", "完成状态")
        try append("event_msg", ["type": "error"])
        try check(try reader.read(path.path) == "error", "显式错误")
        try append("event_msg", ["type": "turn_aborted"])
        try check(try reader.read(path.path) == "unknown" && reader.pending.isEmpty, "取消清除待处理")
        try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}".utf8).write(to: path)
        try check(try reader.read(path.path) == "unknown", "半行不提前消费")
        let tail = try FileHandle(forWritingTo: path); try tail.seekToEnd(); try tail.write(contentsOf: Data([10])); try tail.close()
        try check(try reader.read(path.path) == "running", "半行补齐后消费")

        let id = UUID().uuidString.lowercased()
        var database: OpaquePointer?
        try check(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK, "创建隔离数据库")
        defer { sqlite3_close(database) }
        let sql = "CREATE TABLE threads (id TEXT, rollout_path TEXT, name TEXT, title TEXT, archived INTEGER, source TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('\(id)','\(path.path)','任务','旧标题',0,'appServer',\(Int(Date().timeIntervalSince1970)));"
        try check(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "写入测试任务")
        func unread(_ ids: [String]) throws {
            try writeJSON(["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": ["account": ["local:test": ids]]]], root.appendingPathComponent(".codex-global-state.json"))
        }
        try unread([id])
        let collector = CodexCollector(home: root)
        var items = collector.snapshot()["conversations"] as! [JSONObject]
        try check(items.count == 1 && items[0]["unread"] as? Bool == true && items[0]["state"] as? String == "running", "运行与未读并存")
        try unread([]); items = collector.snapshot()["conversations"] as! [JSONObject]
        try check(items.count == 1 && items[0]["unread"] == nil, "已读不终止运行")
        try append("event_msg", ["type": "task_complete"])
        try check((collector.snapshot()["conversations"] as! [JSONObject]).isEmpty, "完成已读移出列表")
        try unread([id]); try check((collector.snapshot()["conversations"] as! [JSONObject]).count == 1, "完成未读保留")

        let backend = try NativeBackend(token: "test-only")
        let server = try LocalHTTPServer(port: 0, handler: backend.handle); server.start(); defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !server.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let port = server.listener.port else { throw ControlError("测试监听失败") }
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/api/status")!
        try rejects("真实 HTTP 拒绝未认证") { _ = try HTTPFetch.request(url) }
        let snapshot = try HTTPFetch.request(url, token: "test-only") as! JSONObject
        try check(snapshot["schema"] as? Int == 1, "真实 HTTP 鉴权与 JSON 回读")
        try rejects("真实 HTTP 拒绝非法对话 ID") { _ = try HTTPFetch.request(url.deletingLastPathComponent().appendingPathComponent("open"), token: "test-only", body: ["threadId": "file:///tmp"]) }
        try check(backend.handle(HTTPMessage(method: "GET", path: "/.display-token", headers: [:], body: Data())).0 == 404, "私有文件不可访问")
        try check(backend.music.control(["action": "shell", "trackId": "bad"])["ok"] as? Bool == false, "未知媒体命令不可执行")
        server.stop()
        let fixed = try LocalHTTPServer(port: port.rawValue, handler: backend.handle); fixed.start(); defer { fixed.stop() }
        let fixedDeadline = Date().addingTimeInterval(5)
        while !fixed.isRunning && Date() < fixedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try check(fixed.isRunning && fixed.listener.port == port, "固定监听端口不能被改成随机端口")
        try check((try HTTPFetch.request(url, token: "test-only") as? JSONObject)?["schema"] as? Int == 1, "固定端口重新绑定回归")
        let keyStore = LocalKeys(path: root.appendingPathComponent("keys.json"))
        defer { for item in (try? keyStore.records()) ?? [] { if let id = item["id"] as? String { try? Secrets.delete("company-" + id) } } }
        _ = try keyStore.change(["action": "save", "name": "隔离测试", "key": "test-only-not-a-real-key"])
        let first = try keyStore.list()[0], keyID = first["id"] as! String
        try check(first["maskedKey"] as? String == "te****-key" && !(try String(contentsOf: keyStore.path)).contains("test-only-not-a-real-key"), "本地 Key 只存钥匙串且回读遮罩")
        _ = try keyStore.change(["action": "save", "id": keyID, "name": "改名", "key": ""])
        try check(try Secrets.get("company-" + keyID) == "test-only-not-a-real-key", "空 Key 编辑保留原值")
        _ = try keyStore.change(["action": "delete", "id": keyID])
        try check(try keyStore.list().isEmpty && Secrets.get("company-" + keyID) == nil, "删除配置和钥匙串条目")
        print("原生 \(checks) 项断言通过：任务生命周期、未读、歌词、HTTP 边界与鉴权")
    }
}

import Foundation
import SQLite3
import AppKit

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
        // UA 只做展示，覆盖重叠标识、桌面模式与未知客户端，不能用作设备认证。
        for (ua, expected) in [
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0", "Windows · Edge 156"),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Version/18.7.6 Safari/605.1.15", "Mac / iPad（桌面模式） · Safari 18"),
            ("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) Version/18.0 Safari/604.1", "iPad · iPadOS · Safari 18"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0) CriOS/130.0 Safari/604.1", "iPhone · iOS · Chrome 130"),
            ("Mozilla/5.0 (Linux; Android 14) Chrome/130.0 Safari/537.36 EdgA/130.0", "Android · Edge 130"),
            ("Mozilla/5.0 (Linux) Firefox/132.0", "Linux · Firefox 132"),
            ("Mozilla/5.0 (Windows NT 10.0) Chrome/130.0 OPR/115.0", "Windows · Opera 115"),
            ("custom-agent", "未知设备 · 未知浏览器"),
            ("Chrome/", "未知设备 · Chrome"),
            (" \n", "尚未上报设备信息")
        ] { try check(userAgentSummary(ua) == expected, "UA 简介：" + expected) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/native-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try check(secureEqual("abc", "abc") && !secureEqual("abc", "abcd"), "认证比较")
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com/x", "https://example.com?key=x", "file:///tmp", "https://example.com:65536"] {
            try rejects("拒绝不安全地址") { _ = try endpoint(address) }
        }
        try check(try endpoint("http://127.0.0.1:18088").port == 18088, "本机地址可用")
        let legacyTarget = try PairingConnection(config: [:])
        let customTarget = try PairingConnection(config: ["publicURL": "https://display.example.com"])
        try check(legacyTarget.account("device-token") == "device-token", "升级保留旧站点凭据")
        try check(customTarget.url("api/pairing/register").absoluteString == "https://display.example.com/api/pairing/register", "公网注册使用配置地址")
        try check(customTarget.account("device-token") != legacyTarget.account("device-token"), "新服务器不能复用旧凭据")
        try check(try PairingConnection(config: ["publicURL": "https://display.example.com/"]).account("device-token") == customTarget.account("device-token"), "末尾斜杠不改变凭据归属")
        try rejects("未配置时不连接公网") { _ = try PairingConnection(config: ["publicURL": ""]) }

        try check(number(true) == nil && number(Double.infinity) == nil && number(1) == 1, "数字边界")
        try check(lanAddress("192.168.1.2", interface: "en0", type: "IEEE80211", active: true)?["label"] as? String == "Wi-Fi · en0", "Wi-Fi 地址标签")
        try check(lanAddress("10.0.0.2", interface: "en7", type: "Ethernet", active: true)?["url"] as? String == "http://10.0.0.2:18088", "网线地址与端口")
        try check(lanAddress("127.0.0.1", interface: "lo0", type: "Ethernet", active: true) == nil && lanAddress("169.254.1.2", interface: "en0", type: "Ethernet", active: true) == nil, "过滤回环与自分配地址")
        try check(lanAddress("10.0.0.2", interface: "utun0", type: "PPP", active: true) == nil && lanAddress("10.0.0.3", interface: "en0", type: "Ethernet", active: false) == nil, "过滤虚拟与离线接口")
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

        let local = LocalPairing(secret: "isolated-test")
        let code = local.current(now: 1000)
        let paired = local.complete(code, now: 1001)
        let session = paired.1["token"] as! String
        try check(paired.0 == 200 && local.authorized(session, now: 1002), "离线本地配对")
        try check(local.complete(code, now: 1002).0 == 401, "配对码只可使用一次")
        try check(!local.authorized(session + "x", now: 1002), "拒绝篡改会话")
        try check(!local.authorized(session, now: 1001 + 30 * 86400), "会话过期")
        try check(LocalPairing(secret: "isolated-test").authorized(session, now: 1002), "同机重启保留会话")
        try check(!LocalPairing(secret: "other-device").authorized(session, now: 1002), "其他 Mac 不接受会话")
        let expiring = LocalPairing(secret: "expiry")
        let oldCode = expiring.current(now: 1000)
        try check(expiring.complete(oldCode, now: 1600).0 == 401, "配对码过期")
        for _ in 0..<9 { _ = expiring.complete("INVALID!", now: 1601) }
        try check(expiring.complete("INVALID!", now: 1601).0 == 429, "本地配对限流")
        let screensPath = root.appendingPathComponent("local-screens.json")
        let screens = LocalScreens(path: screensPath)
        let multi = LocalPairing(secret: "multi", screens: screens)
        let firstWeb = multi.complete(multi.current(now: 2000), userAgent: "iPad Safari", now: 2001).1["token"] as! String
        let secondWeb = multi.complete(multi.current(now: 2002), userAgent: "Chrome", now: 2003).1["token"] as! String
        try check(multi.authorized(firstWeb, now: 2004) && multi.authorized(secondWeb, now: 2004), "本地多个网页会话同时有效")
        let firstScreen = try screens.list(now: 2004).first { $0["ua"] as? String == "iPad Safari" }!
        let screenID = firstScreen["id"] as! String
        try screens.remark(id: screenID, note: "办公室", now: 2005)
        let reopened = LocalScreens(path: screensPath)
        let restarted = LocalPairing(secret: "multi", screens: reopened)
        try check(restarted.authorized(firstWeb, userAgent: "Updated Safari", now: 2070), "重启后会话有效并更新 UA")
        let screen = try reopened.list(now: 2071).first { $0["id"] as? String == screenID }!
        try check(screen["remark"] as? String == "办公室" && screen["ua"] as? String == "Updated Safari", "跨进程备注与 UA 持久化互不覆盖")
        try check(!(try String(contentsOf: screensPath)).contains(firstWeb), "本地登记不保存会话令牌")
        try rejects("拒绝过长网页备注") { try reopened.remark(id: screenID, note: String(repeating: "字", count: 81), now: 2071) }
        try reopened.revoke(id: screenID, now: 2072)
        try check(!multi.authorized(firstWeb, userAgent: "尝试重新登记", now: 2073), "其他进程踢下线后旧令牌不能重新登记")
        let afterKick = LocalPairing(secret: "multi", screens: LocalScreens(path: screensPath))
        try check(!afterKick.authorized(firstWeb, now: 2074) && afterKick.authorized(secondWeb, now: 2074), "重启后仅被踢端失效，其他端保持连接")
        try check(try reopened.list(now: 2074).count == 1, "已撤销会话不在卡片列表显示")
        try rejects("不能修改已撤销网页") { try reopened.remark(id: screenID, note: "重新备注", now: 2074) }
        let repaired = afterKick.complete(afterKick.current(now: 2075), userAgent: "重新配对", now: 2076).1["token"] as! String
        try check(afterKick.authorized(repaired, now: 2077) && !afterKick.authorized(firstWeb, now: 2077), "重新配对只授予新令牌权限")
        try check(try reopened.list(now: 2001 + 31 * 86400).isEmpty, "列表清理过期网页")
        let disabledMusic = NativeMusic()
        disabledMusic.setEnabled(false)
        try check(disabledMusic.snapshot()["enabled"] as? Bool == false, "停用音乐明确通知网页隐藏歌词")
        disabledMusic.update(["state": "idle"])
        try check(disabledMusic.snapshot()["enabled"] as? Bool == false, "停用时晚到采集不能重新启用")
        disabledMusic.setEnabled(true)
        try check(disabledMusic.snapshot()["enabled"] as? Bool == true, "启用但离线仍保留音乐区域")
        let subscriptions = ConsoleActions(path: root.appendingPathComponent("subscriptions.json"))
        for target in ["all", "paoluz", "sc", "just"] {
            _ = try subscriptions.save(["name": "订阅更新", "kind": "subscription", "target": target])
        }
        try check(try subscriptions.snapshot().count == 4, "订阅配置持久化并纳入快捷快照")
        try check(try subscriptions.snapshot().allSatisfy { $0["lastUpdatedAt"] == nil }, "旧订阅不虚构历史更新时间")
        try subscriptions.recordSubscriptionSuccess("paoluz", at: 1000)
        let firstUpdates = try ConsoleActions(path: subscriptions.path).snapshot()
        try check(firstUpdates[1]["lastUpdatedAt"] as? Double == 1000 && firstUpdates[0]["lastUpdatedAt"] == nil && firstUpdates[2]["lastUpdatedAt"] == nil, "单项成功时间持久化且不改变其他订阅")
        let provider = try subscriptions.list()[1]
        _ = try subscriptions.save(["id": provider["id"]!, "name": "改名订阅", "kind": "subscription", "target": "paoluz", "lastUpdatedAt": 9999])
        try check(try subscriptions.snapshot()[1]["lastUpdatedAt"] as? Double == 1000, "改名保留真实时间且拒绝界面覆盖")
        let commandID = try subscriptions.save(["name": "命令", "kind": "command", "target": "true"])["id"] as! String
        try subscriptions.recordSubscriptionSuccess(nil, at: 2000)
        try check(try subscriptions.snapshot().prefix(4).allSatisfy { $0["lastUpdatedAt"] as? Double == 2000 }, "全部成功同步刷新各个订阅的时间")
        try check(try subscriptions.snapshot().last?["lastUpdatedAt"] == nil, "更新时间不写入非订阅项目")
        try subscriptions.recordSubscriptionSuccess("sc", at: 3000)
        let latestUpdates = try subscriptions.snapshot()
        try check(latestUpdates[2]["lastUpdatedAt"] as? Double == 3000 && latestUpdates[0]["lastUpdatedAt"] as? Double == 2000 && latestUpdates[1]["lastUpdatedAt"] as? Double == 2000, "单项更新不覆盖全部更新及其他订阅的时间")
        for invalid in [0.0, -.infinity, .nan, 253402300800.0] {
            try rejects("无效成功时间不写入配置") { try subscriptions.recordSubscriptionSuccess("sc", at: invalid) }
        }
        try subscriptions.delete(commandID)
        try rejects("订阅范围拒绝任意命令") { _ = try subscriptions.save(["name": "非法", "kind": "subscription", "target": "all; echo bad"]) }
        try ConsoleActions.subscriptionLock.withLock {
            try rejects("新旧订阅入口共用互斥锁") { _ = try ConsoleActions.updateSubscription(nil) }
        }
        try check(try subscriptions.snapshot()[2]["lastUpdatedAt"] as? Double == 3000, "被拒绝的更新不改变上次成功时间")
        let console = ConsoleActions(path: root.appendingPathComponent("console.json"))
        let script = root.appendingPathComponent("test script.sh")
        try "sleep 0.2\nprintf done > result.txt\n".write(to: script, atomically: true, encoding: .utf8)
        let saved = try console.save(["name": "测试脚本", "kind": "script", "target": script.path, "shell": "/bin/bash"])
        let actionID = saved["id"] as! String
        try check(try ConsoleActions(path: console.path).list().count == 1, "快捷项目跨进程持久化")
        try check(try console.snapshot().first?["target"] == nil, "网页快照不包含脚本路径")
        try rejects("拒绝未知解释器") { _ = try console.save(["name": "测试", "kind": "command", "target": "true", "shell": "/usr/bin/env"]) }
        try rejects("拒绝不存在的应用") { _ = try console.save(["name": "测试", "kind": "app", "target": "/missing.app"]) }
        try rejects("拒绝网页传入额外命令") { _ = try console.start(["id": actionID, "target": "echo injected"]) }
        try rejects("拒绝未知快捷项目") { _ = try console.start(["id": UUID().uuidString]) }
        _ = try console.start(["id": actionID])
        try check(try console.snapshot().first?["state"] as? String == "running", "脚本异步运行")
        try rejects("重复执行保护") { _ = try console.start(["id": actionID]) }
        var actionDeadline = Date().addingTimeInterval(3)
        while try console.snapshot().first?["state"] as? String == "running", Date() < actionDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try check(try console.snapshot().first?["state"] as? String == "succeeded", "脚本完成状态")
        try check(try String(contentsOf: root.appendingPathComponent("result.txt")) == "done", "带空格脚本路径及工作目录正确")
        _ = try console.save(["id": actionID, "name": "失败命令", "kind": "command", "target": "exit 7"])
        _ = try console.start(["id": actionID])
        actionDeadline = Date().addingTimeInterval(3)
        while try console.snapshot().first?["state"] as? String == "running", Date() < actionDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try check(try console.snapshot().first?["state"] as? String == "failed", "非零退出显示失败")
        try check(try console.list().count == 1, "编辑保留原项目 ID")
        var dragFrames = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 40),
            "b": CGRect(x: 0, y: 58, width: 100, height: 80),
            "c": CGRect(x: 0, y: 156, width: 100, height: 60),
            "other-group": CGRect(x: 0, y: 300, width: 100, height: 40)
        ]
        var dragDown = ConsoleReorderPlan(sourceID: "a", ids: ["a", "b", "c"], frames: dragFrames)!
        try check(dragDown.sourceID == "a" && dragDown.targetID == nil && dragDown.landingOffset == 0, "拖动初始位置不产生保存目标")
        dragDown.update(centerY: 186)
        try check(dragDown.destination == 2 && dragDown.targetID == "c" && dragDown.landingOffset == 176, "向下跨不同高度行时按目标底边落位")
        try check(dragDown.displacement(for: "b") == -58 && dragDown.displacement(for: "c") == -58, "下移时中间行按源高度与间距向上让位")
        try check(dragDown.displacement(for: "a") == 0 && dragDown.displacement(for: "other-group") == 0, "源行和其他分组不使用让位偏移")
        dragFrames["b"] = CGRect(x: 0, y: 2000, width: 100, height: 80)
        dragDown.update(centerY: 98)
        try check(dragDown.targetID == "b" && dragDown.frames[1].midY == 98, "后续布局变化不改变冻结槽位")
        let frozenFrames = ["a": dragDown.frames[0], "b": dragDown.frames[1], "c": dragDown.frames[2]]
        var dragUp = ConsoleReorderPlan(sourceID: "c", ids: ["a", "b", "c"], frames: frozenFrames)!
        dragUp.update(centerY: 20)
        try check(dragUp.targetID == "a" && dragUp.landingOffset == -156, "向上拖动按目标顶边落位")
        try check(dragUp.displacement(for: "a") == 78 && dragUp.displacement(for: "b") == 78, "上移时中间行向下让位")
        dragUp.update(centerY: 186)
        try check(dragUp.targetID == nil && dragUp.landingOffset == 0 && dragUp.displacement(for: "a") == 0, "回到原位恢复原顺序且无需保存")
        var dragMiddle = ConsoleReorderPlan(sourceID: "b", ids: ["a", "b", "c"], frames: frozenFrames)!
        dragMiddle.update(centerY: 186)
        try check(dragMiddle.landingOffset == 78 && dragMiddle.displacement(for: "c") == -98 && dragMiddle.displacement(for: "a") == 0, "中间行下移保留区间外项目位置")
        dragMiddle.update(centerY: 142)
        try check(dragMiddle.targetID == "c", "等距边界保留当前目标避免反复挤位")
        dragMiddle.update(centerY: .nan)
        try check(dragMiddle.targetID == "c", "忽略非有限拖动坐标")
        var singleDrag = ConsoleReorderPlan(sourceID: "a", ids: ["a"], frames: dragFrames)!
        singleDrag.update(centerY: 1000)
        try check(singleDrag.targetID == nil && singleDrag.displacement(for: "a") == 0, "单项目拖动保持原位")
        try check(ConsoleReorderPlan(sourceID: "missing", ids: ["a"], frames: dragFrames) == nil, "拒绝不存在的拖动源")
        try check(ConsoleReorderPlan(sourceID: "a", ids: ["a", "a"], frames: dragFrames) == nil, "拒绝重复拖动标识")
        try check(ConsoleReorderPlan(sourceID: "a", ids: ["a", "missing"], frames: dragFrames) == nil, "拒绝缺少槽位的分组")
        for invalid in [CGRect(x: 0, y: 0, width: 100, height: 0), CGRect(x: 0, y: 0, width: 100, height: -1), CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 40), CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan)] {
            try check(ConsoleReorderPlan(sourceID: "a", ids: ["a"], frames: ["a": invalid]) == nil, "拒绝无效行几何信息")
        }
        try check(ConsoleReorderPlan(sourceID: "a", ids: ["a"], frames: dragFrames, spacing: -1) == nil && ConsoleReorderPlan(sourceID: "a", ids: ["a"], frames: dragFrames, spacing: .infinity) == nil, "拒绝非法行间距")
        let horizontalFrames = [
            "a": CGRect(x: 10, y: 400, width: 40, height: 60),
            "b": CGRect(x: 68, y: 400, width: 80, height: 60),
            "c": CGRect(x: 166, y: 400, width: 60, height: 60)
        ]
        var dragRight = ConsoleReorderPlan(sourceID: "a", ids: ["a", "b", "c"], frames: horizontalFrames, horizontal: true)!
        dragRight.update(centerY: 196)
        try check(dragRight.horizontal && dragRight.targetID == "c" && dragRight.landingOffset == 176, "横排同高卡片按横坐标向右落位")
        try check(dragRight.displacement(for: "b") == -58 && dragRight.displacement(for: "c") == -58, "向右拖动时中间卡片按源宽度向左让位")
        var dragLeft = ConsoleReorderPlan(sourceID: "c", ids: ["a", "b", "c"], frames: horizontalFrames, horizontal: true)!
        dragLeft.update(centerY: 30)
        try check(dragLeft.targetID == "a" && dragLeft.landingOffset == -156 && dragLeft.displacement(for: "b") == 78, "横排不同宽度卡片向左落位并让位")
        dragLeft.update(centerY: 196)
        try check(dragLeft.targetID == nil && dragLeft.landingOffset == 0 && dragLeft.displacement(for: "a") == 0, "横排回原位不保存且恢复偏移")
        try check(ConsoleReorderPlan(sourceID: "a", ids: ["a"], frames: ["a": CGRect(x: 0, y: 0, width: 0, height: 40)], horizontal: true) == nil, "横排拒绝零宽卡片")
        try check(ConsoleReorderPlan(sourceID: "a", ids: ["a"], frames: ["a": CGRect(x: 0, y: 0, width: 40, height: 0)], horizontal: true) == nil, "横排仍拒绝原始零高卡片")
        let sortStore = ConsoleActions(path: root.appendingPathComponent("sort.json"))
        let firstSort = try sortStore.save(["name": "一", "kind": "command", "target": "true"])["id"] as! String
        let middleSort = try sortStore.save(["name": "脚本", "kind": "script", "target": script.path])["id"] as! String
        let secondSort = try sortStore.save(["name": "二", "kind": "command", "target": "true"])["id"] as! String
        let lastSort = try sortStore.save(["name": "三", "kind": "command", "target": "true"])["id"] as! String
        let originalSort = try sortStore.list()
        try sortStore.move(lastSort, to: firstSort)
        let movedSort = try ConsoleActions(path: sortStore.path).list()
        try check(movedSort.compactMap { $0["id"] as? String } == [lastSort, middleSort, firstSort, secondSort], "向上跨多项拖动持久化且保留其他类型槽位")
        try check(NSDictionary(dictionary: movedSort[1]).isEqual(to: originalSort[1]), "排序保留其他类型配置内容")
        try sortStore.move(lastSort, to: secondSort)
        try check(NSArray(array: sortStore.list()).isEqual(to: originalSort), "向下跨多项拖动保留中间项目顺序")
        try sortStore.move(firstSort, to: firstSort)
        try check(NSArray(array: sortStore.list()).isEqual(to: originalSort), "拖到自身保持不变")
        try rejects("拒绝跨类型拖动") { try sortStore.move(firstSort, to: middleSort) }
        try rejects("拒绝已删除的目标") { try sortStore.move(firstSort, to: UUID().uuidString) }
        try rejects("拒绝未知拖动源") { try sortStore.move(UUID().uuidString, to: firstSort) }
        try check(NSArray(array: sortStore.list()).isEqual(to: originalSort), "无效拖动不改变配置")
        let icon = ConsoleActions.icon("/System/Applications/Calculator.app")
        try check(icon.hasPrefix("data:image/png;base64,") && icon.count <= 53358, "系统应用图标缩略图可同步")
        let iconBitmap = NSBitmapImageRep(data: Data(base64Encoded: String(icon.dropFirst(22)))!)!
        try check(iconBitmap.pixelsWide == 96 && iconBitmap.pixelsHigh == 96, "图标具备 iPad 双倍像素")
        let iconStore = ConsoleActions(path: root.appendingPathComponent("icons.json"))
        let appID = try iconStore.save(["name": "计算器", "kind": "app", "target": "/System/Applications/Calculator.app"])["id"] as! String
        var oldRecords = try iconStore.list()
        oldRecords[0].removeValue(forKey: "iconPixels")
        oldRecords[0]["icon"] = "旧版缓存"
        oldRecords.append(["id": actionID, "name": "命令", "kind": "command", "target": "true"])
        try writeJSON(oldRecords, iconStore.path)
        let upgraded = try iconStore.list()
        try check(upgraded[0]["icon"] as? String == icon && upgraded[0]["iconPixels"] as? Int == 96, "旧图标自动升级")
        try check(upgraded[0]["id"] as? String == appID && upgraded[0]["target"] as? String == "/System/Applications/Calculator.app" && NSDictionary(dictionary: upgraded[1]).isEqual(to: oldRecords[1]), "升级保留 ID、路径和其他项目顺序")
        let cached = try Data(contentsOf: iconStore.path)
        _ = try iconStore.list()
        try check(try Data(contentsOf: iconStore.path) == cached, "高清缓存不重复改写")
        try check(try iconStore.snapshot()[0]["iconPixels"] == nil, "缓存元数据不上传")
        let backend = try NativeBackend(token: "test-only", console: console, screens: LocalScreens())
        let server = try LocalHTTPServer(port: 0, handler: backend.handle); server.start(); defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !server.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let port = server.listener.port else { throw ControlError("测试监听失败") }
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/api/status")!
        try rejects("真实 HTTP 拒绝未认证") { _ = try HTTPFetch.request(url) }
        let localCode = backend.localPairing.current()
        let pairURL = url.deletingLastPathComponent().appendingPathComponent("pairing/complete")
        let pairResult = try HTTPFetch.request(pairURL, body: ["code": localCode]) as! JSONObject
        let webToken = pairResult["token"] as! String
        try check((try HTTPFetch.request(url, token: webToken, header: "X-Pairing-Token") as? JSONObject)?["schema"] as? Int == 1, "HTTP 网页配对读取本地看板")
        try rejects("网页会话不能管理 Key") {
            _ = try HTTPFetch.request(url.deletingLastPathComponent().appendingPathComponent("relay/keys"), token: webToken, body: ["action": "delete"], header: "X-Pairing-Token")
        }
        try check(backend.handle(HTTPMessage(method: "POST", path: "/api/relay/keys?x=1", headers: ["x-pairing-token": webToken], body: Data("{}".utf8))).0 == 403, "查询参数不能绕过管理权限")
        try check(backend.handle(HTTPMessage(method: "GET", path: "/api/console", headers: [:], body: Data())).0 == 401, "控制台拒绝未配对访问")
        let consoleURL = url.deletingLastPathComponent().appendingPathComponent("console")
        let remoteItems = try HTTPFetch.request(consoleURL, token: webToken, header: "X-Pairing-Token") as! [JSONObject]
        try check(remoteItems.count == 1 && remoteItems[0]["target"] == nil, "本地 HTTP 仅返回快捷项目展示信息")
        try check(backend.handle(HTTPMessage(method: "POST", path: "/api/console/save", headers: ["x-pairing-token": webToken], body: Data("{}".utf8))).0 == 404, "网页不能创建快捷项目")
        try console.delete(actionID)
        try rejects("删除立即阻止后续执行") { _ = try HTTPFetch.request(consoleURL.appendingPathComponent("run"), token: webToken, body: ["id": actionID], header: "X-Pairing-Token") }
        try check(try console.list().isEmpty, "删除不影响脚本文件")
        try check(FileManager.default.fileExists(atPath: script.path), "删除快捷入口保留源文件")
        let snapshot = try HTTPFetch.request(url, token: "test-only") as! JSONObject
        try check(snapshot["schema"] as? Int == 1, "真实 HTTP 鉴权与 JSON 回读")
        try rejects("真实 HTTP 拒绝非法对话 ID") { _ = try HTTPFetch.request(url.deletingLastPathComponent().appendingPathComponent("open"), token: "test-only", body: ["threadId": "file:///tmp"]) }
        try check(backend.handle(HTTPMessage(method: "GET", path: "/.display-token", headers: [:], body: Data())).0 == 404, "私有文件不可访问")
        try check(backend.music.control(["action": "shell", "trackId": "bad"])["ok"] as? Bool == false, "未知媒体命令不可执行")
        server.stop()
        let fixed = try LocalHTTPServer(port: port.rawValue, host: "0.0.0.0", handler: backend.handle); fixed.start(); defer { fixed.stop() }
        let fixedDeadline = Date().addingTimeInterval(5)
        while !fixed.isRunning && Date() < fixedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try check(fixed.isRunning && fixed.listener.port == port, "固定监听端口不能被改成随机端口")
        try check((try HTTPFetch.request(url, token: "test-only") as? JSONObject)?["schema"] as? Int == 1, "固定端口重新绑定回归")
        let publicServer = try LocalHTTPServer(port: 0) { request in
            let valid = request.path == "/api/mode" && request.headers["x-device-token"] == nil && request.headers["x-display-token"] == nil
            return (valid ? 200 : 400, "application/json", Data("{\"mode\":\"pairing\"}".utf8))
        }
        publicServer.start(); defer { publicServer.stop() }
        let publicDeadline = Date().addingTimeInterval(5)
        while !publicServer.isRunning && Date() < publicDeadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let publicPort = publicServer.listener.port else { throw ControlError("公网配置测试监听失败") }
        try check(try validatePublicAddress("http://127.0.0.1:\(publicPort.rawValue)/") == "http://127.0.0.1:\(publicPort.rawValue)", "保存前实际探测配对能力且不携带凭据")
        let legacyServer = try LocalHTTPServer(port: 0) { _ in (200, "application/json", Data("{\"mode\":\"legacy\"}".utf8)) }
        legacyServer.start(); defer { legacyServer.stop() }
        let legacyDeadline = Date().addingTimeInterval(5)
        while !legacyServer.isRunning && Date() < legacyDeadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let legacyPort = legacyServer.listener.port else { throw ControlError("旧模式测试监听失败") }
        try rejects("拒绝普通网站或旧版接口") { _ = try validatePublicAddress("http://127.0.0.1:\(legacyPort.rawValue)") }
        let keyStore = LocalKeys(path: root.appendingPathComponent("keys.json"))
        try check((try managedKeys(localStore: keyStore) as? [JSONObject])?.isEmpty == true, "无需启动看板即可读取空 Key 列表")
        try check(try keyStore.station() == nil, "新安装先添加站点")
        try rejects("没有站点时禁止添加 Key") { _ = try keyStore.change(["action": "save", "name": "测试", "key": "test-only-not-a-real-key"]) }
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com?key=x", "https://example.com/v1/usage"] {
            try rejects("拒绝不安全或歧义站点地址") { _ = try LocalKeys.stationURL(address) }
        }
        _ = try keyStore.saveStation(["type": "sub2api", "name": "测试站", "url": "https://example.com/v1/"])
        try check(try keyStore.usageURL().absoluteString == "https://example.com/v1/usage", "额度接口使用配置地址且不重复 v1")
        try rejects("暂不支持其他中转站类型") { _ = try keyStore.saveStation(["type": "other", "name": "测试", "url": "https://example.com"]) }
        defer { for item in (try? keyStore.records()) ?? [] { if let id = item["id"] as? String { try? Secrets.delete("company-" + id) } } }
        _ = try managedKeys(["action": "save", "name": "隔离测试", "key": "test-only-not-a-real-key"], localStore: keyStore)
        let first = try keyStore.list()[0], keyID = first["id"] as! String
        try check(first["maskedKey"] as? String == "te****-key" && !(try String(contentsOf: keyStore.path)).contains("test-only-not-a-real-key"), "本地 Key 只存钥匙串且回读遮罩")
        _ = try managedKeys(["action": "save", "id": keyID, "name": "改名", "key": ""], localStore: keyStore)
        try check(try Secrets.get("company-" + keyID) == "test-only-not-a-real-key", "空 Key 编辑保留原值")
        try rejects("已有 Key 时更换站点地址必须确认") { _ = try keyStore.saveStation(["type": "sub2api", "name": "新站", "url": "https://other.example.com"]) }
        _ = try keyStore.saveStation(["type": "sub2api", "name": "新站", "url": "https://other.example.com", "confirmAddressChange": true])
        try check(try keyStore.usageURL().host == "other.example.com", "确认后使用新站点地址")
        let usageServer = try LocalHTTPServer(port: 0) { request in
            let valid = request.path == "/v1/usage" && request.headers["authorization"] == "Bearer test-only-not-a-real-key"
            return (valid ? 200 : 400, "application/json", Data("{\"isValid\":true,\"remaining\":42,\"unit\":\"USD\"}".utf8))
        }
        usageServer.start(); defer { usageServer.stop() }
        let usageDeadline = Date().addingTimeInterval(5)
        while !usageServer.isRunning && Date() < usageDeadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let usagePort = usageServer.listener.port else { throw ControlError("额度测试监听失败") }
        _ = try keyStore.saveStation(["type": "sub2api", "name": "本机测试", "url": "http://127.0.0.1:\(usagePort.rawValue)", "confirmAddressChange": true])
        try check(try number(keyStore.usage(keyID, force: true)["remaining"]) == 42, "实际额度请求使用所填地址、正确路径与鉴权")
        let otherStore = LocalKeys(path: keyStore.path)
        _ = try otherStore.saveStation(["type": "sub2api", "name": "另一地址", "url": "http://127.0.0.1:\(port.rawValue)", "confirmAddressChange": true])
        try check(try keyStore.usage(keyID, force: false)["error"] != nil, "其他进程改地址后不能复用旧额度缓存")
        try FileManager.default.removeItem(at: keyStore.stationPath)
        try check(try keyStore.usageURL().host == "sub2api.818tu.com", "旧 Key 升级保持原站点归属")
        _ = try managedKeys(["action": "delete", "id": keyID], localStore: keyStore)
        try check(try keyStore.list().isEmpty && Secrets.get("company-" + keyID) == nil, "删除配置和钥匙串条目")
        print("原生 \(checks) 项断言通过：任务生命周期、未读、歌词、HTTP 边界与鉴权")
    }
}

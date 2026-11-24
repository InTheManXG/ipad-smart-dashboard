import Foundation

@main struct ServiceLifecycleTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ControlError("验证失败：" + message) }
        checks += 1
    }

    static func wait(_ message: String, until condition: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while try !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try check(try condition(), message)
    }

    final class Fixture {
        let directory: URL
        let target: String
        let plist: URL
        let runtime: URL

        init(heartbeat: Bool = true, tailHeartbeat: Bool = false) throws {
            let id = UUID().uuidString.lowercased()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-service-test-" + id)
            target = NativePaths.domain + "/com.iamxg.ipad-service-test." + id
            plist = directory.appendingPathComponent("agent.plist")
            runtime = directory.appendingPathComponent("runtime.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // launchd 子进程不能读取 Downloads 下的脚本，使用内联命令和独立临时目录。
            let output = "'" + runtime.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let publish = """
                /usr/bin/perl -MTime::HiRes=time -e 'printf "{\\"updatedAt\\":%.6f}\\n", time' > \(output).new
                /bin/mv -f \(output).new \(output)
                """
            // 首个进程退出时留下新快照，后继进程不再写入，暴露跨进程误认心跳。
            let finish = tailHeartbeat ? "/bin/sleep 0.7; publish; /bin/sleep 1.3" : "/bin/sleep 2"
            let firstProcessOnly = tailHeartbeat ? """
                if [[ -f \(output).started ]]; then enabled=false; fi
                /usr/bin/touch \(output).started
                """ : ""
            let script = """
                publish() {
                  \(publish)
                }
                finish() { \(finish); exit 0; }
                trap finish TERM
                enabled=\(heartbeat ? "true" : "false")
                \(firstProcessOnly)
                while :; do
                  if "$enabled"; then publish; fi
                  /bin/sleep 0.2
                done
                """
            let properties: JSONObject = [
                "Label": String(target.split(separator: "/").last!),
                "ProgramArguments": ["/bin/bash", "-c", script],
                "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Interactive", "ThrottleInterval": 1
            ]
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        }

        func start() throws {
            try startService(target: target, plist: plist, runtime: runtime, timeout: 8)
        }

        func state() throws -> String? {
            try serviceInfo(target: target)?.components(separatedBy: .newlines)
                .map(trimmed).first { $0.hasPrefix("state = ") }
        }

        func pid() throws -> String? {
            try serviceInfo(target: target)?.components(separatedBy: .newlines)
                .map(trimmed).first { $0.hasPrefix("pid = ") }
        }

        func cleanup() throws {
            try stopService(target: target, timeout: 8)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    static func testHealthyStartAndStop() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        try fixture.start()
        let pid = try fixture.pid()
        try check(pid != nil, "测试后台实际运行")
        try fixture.start()
        try check(try fixture.pid() == pid, "健康后台再次启动保留原进程")

        let started = ProcessInfo.processInfo.systemUptime
        try stopService(target: fixture.target, timeout: 8)
        try check(ProcessInfo.processInfo.systemUptime - started >= 1.8, "停止须等待延迟退出，不能仅接受 bootout 成功")
        try check(try serviceInfo(target: fixture.target) == nil, "停止返回时 job 已真正移除")
        try fixture.cleanup()
    }

    static func testStartDuringRemoval() throws {
        let fixture = try Fixture()
        defer { try? fixture.cleanup() }
        try fixture.start()
        let oldPID = try fixture.pid()
        let result = try execute("/bin/launchctl", ["bootout", fixture.target])
        try check(result.0 == 0, "模拟旧版 App 异步卸载后台")
        try wait("旧 job 进入尚未移除的退出阶段") { try fixture.state() == "state = SIGTERMed" }
        try fixture.start()
        let newPID = try fixture.pid()
        try check(newPID != nil && newPID != oldPID, "启动须等待旧 job 移除后注册新进程")
        Thread.sleep(forTimeInterval: 0.4)
        try check(try fixture.state() == "state = running" && fixture.pid() == newPID, "新进程不会随后被旧 bootout 移除")
        try fixture.cleanup()
    }

    static func testStaleHeartbeat() throws {
        let fixture = try Fixture(heartbeat: false)
        defer { try? fixture.cleanup() }
        // 两秒前的快照仍很新，但不属于本次启动，不能拿它证明后台已恢复。
        try writeJSON(["updatedAt": Date().timeIntervalSince1970 - 2], fixture.runtime)
        let result = try execute("/bin/launchctl", ["bootstrap", NativePaths.domain, fixture.plist.path])
        try check(result.0 == 0, "启动无心跳的隔离后台")
        try wait("无心跳后台实际运行") { try fixture.state() == "state = running" }
        var rejected = false
        do { try startService(target: fixture.target, plist: fixture.plist, runtime: fixture.runtime, timeout: 0.7) }
        catch { rejected = true }
        try check(rejected, "job 存在和陈旧心跳不能判作启动成功")
        try fixture.cleanup()
    }

    static func testTailHeartbeat() throws {
        let fixture = try Fixture(tailHeartbeat: true)
        defer { try? fixture.cleanup() }
        try fixture.start()
        let oldPID = try fixture.pid()
        let result = try execute("/bin/launchctl", ["bootout", fixture.target])
        try check(result.0 == 0, "触发会写尾部心跳的旧进程退出")
        try wait("旧进程写尾部心跳前开始新启动请求") { try fixture.state() == "state = SIGTERMed" }
        let requestedAt = Date().timeIntervalSince1970
        var rejected = false
        do { try startService(target: fixture.target, plist: fixture.plist, runtime: fixture.runtime, timeout: 4) }
        catch { rejected = true }
        let tail = try readJSON(fixture.runtime)
        try check((number(tail["updatedAt"]) ?? 0) > requestedAt, "旧进程尾部快照晚于本次启动请求")
        try check(try fixture.state() == "state = running" && fixture.pid() != oldPID, "新进程已运行但没有产生自己的心跳")
        try check(rejected, "不能用旧进程退出时的心跳确认新进程就绪")
        try fixture.cleanup()
    }

    static func main() throws {
        try testHealthyStartAndStop()
        try testStartDuringRemoval()
        try testStaleHeartbeat()
        try testTailHeartbeat()
        print("后台生命周期隔离 \(checks) 项检查通过：等待卸载、旧版升级接管、心跳校验与健康进程保持")
    }
}

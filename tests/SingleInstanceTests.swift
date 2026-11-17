import Foundation
import Darwin

@main struct SingleInstanceTests {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
        checks += 1
    }

    static func childMode() throws {
        let mode = CommandLine.arguments[1]
        let path = URL(fileURLWithPath: CommandLine.arguments[2])
        let instance: SingleInstanceLock
        do {
            guard let acquired = try SingleInstanceLock.acquire(at: path) else { exit(2) }
            instance = acquired
        } catch { exit(3) }
        withExtendedLifetime(instance) {
            if mode == "--probe" { return }
            _ = FileManager.default.createFile(atPath: CommandLine.arguments[3], contents: Data())
            if mode == "--exec" {
                // exec 不执行 Swift 析构；只有 CLOEXEC 能确保新程序不继续持有 GUI 锁。
                var args: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("5"), nil]
                execv("/bin/sleep", &args)
                exit(4)
            }
            _ = FileHandle.standardInput.readDataToEndOfFile()
        }
    }

    static func process(_ arguments: [String], input: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = arguments
        process.standardInput = input ?? Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func wait(until ready: () -> Bool, _ message: String) throws {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try check(ready(), message)
    }

    static func probe(_ path: URL) throws -> Int32 {
        let child = try process(["--probe", path.path])
        try wait(until: { !child.isRunning }, "探测子进程应及时退出")
        return child.terminationStatus
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 { try childMode(); return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ipad-single-instance-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let path = root.appendingPathComponent("nested/gui.lock")

        // 两个独立启动进程同时争抢，获胜者保持锁，落败者不能成为第二个 GUI。
        let inputs = [Pipe(), Pipe()]
        let ready = [root.appendingPathComponent("ready-a"), root.appendingPathComponent("ready-b")]
        var children = [Process]()
        defer {
            for input in inputs { try? input.fileHandleForWriting.close() }
            for child in children where child.isRunning { child.terminate(); child.waitUntilExit() }
        }
        for index in 0..<2 {
            children.append(try process(["--hold", path.path, ready[index].path], input: inputs[index]))
        }
        try wait(until: {
            ready.filter { fm.fileExists(atPath: $0.path) }.count == 1 && children.filter { !$0.isRunning }.count == 1
        }, "并发启动只能产生一个锁持有者")
        let winner = children.firstIndex { $0.isRunning }!
        try check(children[1 - winner].terminationStatus == 2, "重复实例以占用状态退出")
        try check(try probe(path) == 2, "持锁期间其他进程不能进入")

        try inputs[winner].fileHandleForWriting.close()
        try wait(until: { !children[winner].isRunning }, "关闭持有者后应退出")
        try check(children[winner].terminationStatus == 0, "正常退出成功")
        try check(fm.fileExists(atPath: path.path), "退出保留锁文件，避免换 inode 产生双锁")
        try check(try probe(path) == 0, "正常退出后可重新启动")

        let crashInput = Pipe(), crashReady = root.appendingPathComponent("ready-crash")
        let crashed = try process(["--hold", path.path, crashReady.path], input: crashInput)
        children.append(crashed)
        try wait(until: { fm.fileExists(atPath: crashReady.path) }, "异常退出夹具取得锁")
        crashed.terminate()
        try wait(until: { !crashed.isRunning }, "异常退出夹具终止")
        try check(try probe(path) == 0, "异常退出后内核释放锁，不依赖清理 PID 文件")

        let execReady = root.appendingPathComponent("ready-exec")
        let executed = try process(["--exec", path.path, execReady.path])
        children.append(executed)
        try wait(until: { fm.fileExists(atPath: execReady.path) }, "exec 夹具取得锁")
        var released = false
        try wait(until: {
            released = (try? probe(path)) == 0
            return released
        }, "exec 后的子程序不能继承 GUI 锁")
        try check(executed.isRunning, "锁已释放时 exec 子程序仍在运行")
        executed.terminate()
        try wait(until: { !executed.isRunning }, "exec 夹具终止")

        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedParent)
        try check(try probe(blockedParent.appendingPathComponent("gui.lock")) == 3, "文件系统错误不能当成成功或重复实例")
        try check(try probe(root) == 3, "目录不能当作锁文件打开")
        let link = root.appendingPathComponent("redirect.lock")
        try fm.createSymbolicLink(at: link, withDestinationURL: path)
        try check(try probe(link) == 3, "符号链接不能重定向实例锁")
        print("单实例隔离进程 \(checks) 项检查通过：并发互斥、退出释放、exec 关闭与失败保护")
    }
}

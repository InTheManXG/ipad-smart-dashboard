import Foundation
import Darwin
import AppKit

final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 子进程不能继承前台锁，否则 App 退出后后台仍会阻止重新打开。
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        // 锁文件保留同一 inode，避免删除重建后两个实例各锁住不同文件。
        return SingleInstanceLock(descriptor: descriptor)
    }
}

enum ControlAppInstance {
    private static var lock: SingleInstanceLock?

    static func acquireOrExit() {
        guard lock == nil else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iPadControl/control-app.lock")
        do {
            guard let acquired = try SingleInstanceLock.acquire(at: path) else {
                // 重复实例不能调用 NSApp.terminate，它会误停主实例的共享后台。
                if !CommandLine.arguments.contains("--background"),
                   let identifier = Bundle.main.bundleIdentifier,
                   let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first(where: { $0.processIdentifier != getpid() }) {
                    // 普通 activate 不会重建已关闭的窗口，交给 LaunchServices 发送重新打开事件。
                    let reopen = Process()
                    reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    reopen.arguments = ["-a", (existing.bundleURL ?? Bundle.main.bundleURL).path]
                    if (try? reopen.run()) != nil { reopen.waitUntilExit() }
                    else { existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
                }
                exit(0)
            }
            lock = acquired
        } catch {
            fputs("无法取得控制台实例锁，已停止启动以避免重复运行。\n", stderr)
            exit(1)
        }
    }
}

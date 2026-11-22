import Foundation
import Darwin

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let adapter = root.appendingPathComponent(".build/iPad 控制台.app/Contents/Resources/MediaAdapter")
let process = Process()
let output = Pipe()
process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
process.arguments = [adapter.appendingPathComponent("mediaremote-adapter.pl").path,
                     adapter.appendingPathComponent("MediaRemoteAdapter.framework").path,
                     adapter.appendingPathComponent("MediaRemoteAdapterTestClient").path,
                     "get", "--no-artwork", "--now"]
process.standardOutput = output
// 丢弃组件错误详情，避免媒体信息进入构建日志，也不会堵住 stderr 管道。
process.standardError = FileHandle.nullDevice
do {
    try process.run()
} catch {
    fail("媒体组件加载或只读查询失败")
}

let descriptor = output.fileHandleForReading.fileDescriptor
let flags = fcntl(descriptor, F_GETFL)
guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    fail("媒体组件输出读取失败")
}
defer { try? output.fileHandleForReading.close() }

var data = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
let deadline = ProcessInfo.processInfo.systemUptime + 15
var ended = false
while !ended || process.isRunning {
    // 同时排空 stdout 并检查超时，不会因组件输出填满管道而死锁。
    if ProcessInfo.processInfo.systemUptime >= deadline {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        fail("媒体组件只读查询超时")
    }
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    if count > 0 {
        // 只读快照不应无限增长，异常组件输出不能耗尽构建进程内存。
        if data.count + count > 4 * 1024 * 1024 {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            fail("媒体组件输出超过安全大小")
        }
        data.append(contentsOf: buffer.prefix(count))
    } else if count == 0 {
        ended = true
    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        fail("媒体组件输出读取失败")
    }
    if count <= 0 { usleep(10000) }
}
process.waitUntilExit()
guard process.terminationStatus == 0 else { fail("媒体组件加载或只读查询失败") }
guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      value is [String: Any] || value is NSNull else {
    fail("媒体查询未返回合法快照")
}
print("当前系统的媒体组件加载与只读查询通过")

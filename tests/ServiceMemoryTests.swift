import Foundation
import Darwin

@main struct ServiceMemoryTests {
    static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ControlError("无法读取内存占用") }
        return UInt64(info.resident_size)
    }

    static func main() {
        let music = NativeMusic()
        Thread.detachNewThread { music.run() }
        Thread.detachNewThread {
            do {
                // 先让媒体子进程、动态库和超时回调完成预热，再测持续轮询的增长。
                Thread.sleep(forTimeInterval: 5)
                guard music.snapshot()["state"] as? String == "idle" else { throw ControlError("媒体测试夹具未正常运行") }
                let before = try residentBytes()
                Thread.sleep(forTimeInterval: 20)
                let after = try residentBytes()
                let counter = NativePaths.resources.appendingPathComponent("MediaAdapter/calls")
                let calls = try Data(contentsOf: counter).count
                guard calls >= 70 else { throw ControlError("媒体轮询次数不足：\(calls)") }
                let growth = after > before ? after - before : 0
                guard growth < 16 * 1024 * 1024 else {
                    throw ControlError("持续音乐轮询内存增长过大：\(growth / 1024 / 1024) MiB")
                }
                print("内存回归通过：\(calls) 次真实音乐轮询，预热后增长 \(growth / 1024) KiB")
                exit(0)
            } catch {
                fputs("内存回归失败：\((error as? ControlError)?.message ?? String(describing: error))\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }
}

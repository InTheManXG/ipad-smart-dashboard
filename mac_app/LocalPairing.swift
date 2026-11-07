import Foundation
import CryptoKit
import Darwin

// 只保存网页标识和展示信息，不保存会话令牌；文件锁协调 GUI 与后台进程。
final class LocalScreens {
    private let lock = NSLock()
    private let path: URL?
    private var memory = [JSONObject]()
    init(path: URL? = nil) { self.path = path }
    private func access<T>(now: TimeInterval, _ action: (inout [JSONObject]) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var fd: Int32 = -1
        if let path {
            fd = open(path.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw ControlError("无法读取已配对网页") }
            guard flock(fd, LOCK_EX) == 0 else { close(fd); throw ControlError("无法锁定已配对网页") }
        }
        defer { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd) } }
        var records = memory
        if let path, FileManager.default.fileExists(atPath: path.path) {
            guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [JSONObject] else { throw ControlError("已配对网页记录损坏，拒绝覆盖") }
            records = saved
        }
        let before = records
        records.removeAll { (number($0["expires"]) ?? 0) <= now }
        let result = try action(&records)
        if !NSArray(array: before).isEqual(to: records) {
            if let path { try writeJSON(records, path) } else { memory = records }
        }
        return result
    }
    func list(now: TimeInterval = Date().timeIntervalSince1970) throws -> [JSONObject] {
        try access(now: now) { $0.filter { $0["revoked"] as? Bool != true }.sorted { (number($0["seen"]) ?? 0) > (number($1["seen"]) ?? 0) } }
    }
    func touch(id: String, expires: TimeInterval, ua: String?, now: TimeInterval) throws -> Bool {
        try access(now: now) { records in
            let agent = ua.map { String($0.prefix(1024)) }
            if let index = records.firstIndex(where: { $0["id"] as? String == id }) {
                guard records[index]["revoked"] as? Bool != true else { return false }
                if let agent, records[index]["ua"] as? String != agent || now - (number(records[index]["seen"]) ?? 0) >= 60 {
                    records[index]["ua"] = agent; records[index]["seen"] = now
                }
            } else {
                records.append(["id": id, "remark": "", "ua": agent ?? "", "seen": now, "expires": expires])
            }
            return true
        }
    }
    func revoke(id: String, now: TimeInterval = Date().timeIntervalSince1970) throws {
        try access(now: now) { records in
            guard let index = records.firstIndex(where: { $0["id"] as? String == id && $0["revoked"] as? Bool != true }) else { throw ControlError("网页配对已过期或不存在") }
            // 签名令牌不能靠删登记失效；保留撤销标记至令牌过期，阻止旧令牌再次登记。
            records[index]["revoked"] = true
        }
    }
    func remark(id: String, note: String, now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard UUID(uuidString: id) != nil, trimmed(note).count <= 80 else { throw ControlError("备注不能超过 80 个字符") }
        try access(now: now) { records in
            guard let index = records.firstIndex(where: { $0["id"] as? String == id && $0["revoked"] as? Bool != true }) else { throw ControlError("网页配对已过期或不存在") }
            records[index]["remark"] = trimmed(note)
        }
    }
}

// 本地配对完全由 App 完成；会话签名绑定本机钥匙串口令，不依赖公网或数据库。
final class LocalPairing {
    private let lock = NSLock()
    private let key: SymmetricKey
    private let screens: LocalScreens
    private var code = "", expires: TimeInterval = 0
    private var attempts = 0, window: TimeInterval = 0
    init(secret: String, screens: LocalScreens = LocalScreens()) { key = SymmetricKey(data: Data(secret.utf8)); self.screens = screens }
    private func rotate(_ now: TimeInterval) {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        code = String((0..<8).map { _ in alphabet.randomElement()! })
        expires = now + 600
    }
    func current(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        lock.lock(); defer { lock.unlock() }
        if expires <= now { rotate(now) }
        return code
    }
    private func signature(_ payload: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
    func complete(_ supplied: String, userAgent: String = "", now: TimeInterval = Date().timeIntervalSince1970) -> (Int, JSONObject) {
        lock.lock(); defer { lock.unlock() }
        // 按整个本地监听器限流，不能伪造转发 IP 绕过尝试次数。
        if now - window >= 60 { window = now; attempts = 0 }
        guard attempts < 10 else { return (429, ["error": "too_many_requests"]) }
        attempts += 1
        guard expires > now, secureEqual(supplied.uppercased(), code) else { return (401, ["error": "invalid_pairing_code"]) }
        let id = UUID().uuidString.lowercased(), expiry = now + 30 * 86400
        do {
            guard try screens.list(now: now).count < 16 else { return (409, ["error": "screen_limit"]) }
            _ = try screens.touch(id: id, expires: expiry, ua: userAgent, now: now)
        } catch { return (503, ["error": "storage_unavailable"]) }
        let payload = id + "." + String(Int(expiry))
        rotate(now) // 同一码只能消费一次，其他屏幕须使用新码。
        return (200, ["token": payload + "." + signature(payload)])
    }
    func authorized(_ token: String, userAgent: String? = nil, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard token.utf8.count <= 200 else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, UUID(uuidString: String(parts[0])) != nil,
              let expiry = TimeInterval(parts[1]), expiry.isFinite, expiry > now else { return false }
        guard secureEqual(String(parts[2]), signature(String(parts[0]) + "." + String(parts[1]))) else { return false }
        // 每次访问都核对持久化撤销状态；无法读取记录时拒绝访问，不能绕过踢下线。
        return (try? screens.touch(id: String(parts[0]), expires: expiry, ua: userAgent, now: now)) ?? false
    }
}

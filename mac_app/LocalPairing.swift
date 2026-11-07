import Foundation
import CryptoKit

// 本地配对完全由 App 完成；会话签名绑定本机钥匙串口令，不依赖公网或数据库。
final class LocalPairing {
    private let lock = NSLock()
    private let key: SymmetricKey
    private var code = "", expires: TimeInterval = 0
    private var attempts = 0, window: TimeInterval = 0
    init(secret: String) { key = SymmetricKey(data: Data(secret.utf8)) }
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
    func complete(_ supplied: String, now: TimeInterval = Date().timeIntervalSince1970) -> (Int, JSONObject) {
        lock.lock(); defer { lock.unlock() }
        // 按整个本地监听器限流，不能伪造转发 IP 绕过尝试次数。
        if now - window >= 60 { window = now; attempts = 0 }
        guard attempts < 10 else { return (429, ["error": "too_many_requests"]) }
        attempts += 1
        guard expires > now, secureEqual(supplied.uppercased(), code) else { return (401, ["error": "invalid_pairing_code"]) }
        let payload = UUID().uuidString.lowercased() + "." + String(Int(now + 30 * 86400))
        rotate(now) // 同一码只能消费一次，其他屏幕须使用新码。
        return (200, ["token": payload + "." + signature(payload)])
    }
    func authorized(_ token: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard token.utf8.count <= 200 else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, UUID(uuidString: String(parts[0])) != nil,
              let expiry = TimeInterval(parts[1]), expiry.isFinite, expiry > now else { return false }
        return secureEqual(String(parts[2]), signature(String(parts[0]) + "." + String(parts[1])))
    }
}

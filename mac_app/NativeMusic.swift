import Foundation
import CryptoKit

func matches(_ pattern: String, _ value: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let string = value as NSString
    return regex.matches(in: value, range: NSRange(location: 0, length: string.length)).map { match in
        (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
    }
}
func normalizeSong(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}
func parseLyrics(_ text: String) -> [JSONObject] {
    let offset = (matches(#"\[offset:([+-]?\d+)\]"#, text).first.flatMap { Double($0[1]) } ?? 0) / 1000
    var groups = [Double: [String]]()
    for line in text.components(separatedBy: .newlines) {
        let tags = matches(#"\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]"#, line)
        let content = String(trimmed(line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)).prefix(300))
        for tag in tags {
            let stamp = max(0, (Double(tag[1]) ?? 0) * 60 + (Double(tag[2]) ?? 0) + (Double("0." + tag[3]) ?? 0) - offset)
            if stamp > 86400 { continue }
            if groups[stamp] == nil { groups[stamp] = [] }
            if !content.isEmpty && !groups[stamp]!.contains(content) { groups[stamp]!.append(content) }
        }
    }
    return groups.keys.sorted().prefix(1000).map { ["time": $0, "text": String(groups[$0]!.joined(separator: " / ").prefix(300))] }
}
func lyricFetch(_ path: String, _ values: [String: String]) throws -> JSONObject {
    var url = URLComponents(string: "https://music.163.com/api/" + path)!
    url.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let result = try HTTPFetch.request(url.url!, timeout: 6) as? JSONObject, result["code"] as? Int == 200 else { throw ControlError("歌词服务暂不可用") }
    return result
}
func findLyrics(_ track: JSONObject) throws -> [JSONObject] {
    let title = normalizeSong(track["title"] as? String ?? ""), artist = normalizeSong(track["artist"] as? String ?? "")
    let album = normalizeSong(track["album"] as? String ?? ""), duration = number(track["duration"]) ?? 0
    var songID: Int?
    // 保留已核实的旧版补录，不能用其他同名版本的时间轴代替。
    if title == "梦醒时分" && artist == "周冰倩" && album == "梦醒时分" && abs(duration - 244.333) <= 1 { songID = 334909 }
    if songID == nil {
        let result = try lyricFetch("search/get", ["s": (track["title"] as? String ?? "") + " " + (track["artist"] as? String ?? ""), "type": "1", "limit": "30"])
        let songs = (result["result"] as? JSONObject)?["songs"] as? [JSONObject] ?? []
        var candidates = [(Bool, Double, Int)]()
        for song in songs {
            let artists = (song["artists"] as? [JSONObject] ?? []).map { normalizeSong($0["name"] as? String ?? "") }
            let delta = abs((number(song["duration"]) ?? 0) / 1000 - duration)
            if normalizeSong(song["name"] as? String ?? "") == title && !artist.isEmpty && (artists.contains(artist) || artists.joined() == artist) && delta <= 4, let id = song["id"] as? Int {
                candidates.append((normalizeSong((song["album"] as? JSONObject)?["name"] as? String ?? "") != album, delta, id))
            }
        }
        songID = candidates.sorted { $0.0 != $1.0 ? !$0.0 : ($0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2) }.first?.2
    }
    guard let id = songID else { return [] }
    let data = try lyricFetch("song/lyric", ["id": String(id), "lv": "-1", "kv": "-1", "tv": "-1"])
    return parseLyrics((data["lrc"] as? JSONObject)?["lyric"] as? String ?? "")
}

func media(_ arguments: [String]) throws -> Data {
    let base = NativePaths.resources.appendingPathComponent("MediaAdapter")
    let result = try execute("/usr/bin/perl", [base.appendingPathComponent("mediaremote-adapter.pl").path,
        base.appendingPathComponent("MediaRemoteAdapter.framework").path,
        base.appendingPathComponent("MediaRemoteAdapterTestClient").path] + arguments, timeout: 4)
    guard result.0 == 0 else { throw ControlError("系统媒体接口不可用") }
    return result.1
}
func readPlayer() throws -> JSONObject {
    let data = try media(["get", "--no-artwork", "--now"])
    guard let player = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? JSONObject else { return ["state": "idle"] }
    let sources = ["com.netease.163music": "网易云音乐", "com.apple.Music": "Apple Music", "com.spotify.client": "Spotify", "com.tencent.QQMusicMac": "QQ 音乐"]
    guard let bundle = player["bundleIdentifier"] as? String, let source = sources[bundle] else { return ["state": "idle"] }
    guard let duration = number(player["duration"]), let position = number(player["elapsedTimeNow"] ?? player["elapsedTime"]) else { return ["state": "unavailable"] }
    let title = player["title"] as? String ?? "", artist = player["artist"] as? String ?? "", album = player["album"] as? String ?? ""
    let identity = try jsonData([bundle, title, artist, album, duration])
    let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return ["state": "ready", "title": String(title.prefix(300)), "artist": String(artist.prefix(300)), "album": String(album.prefix(300)), "source": source,
            "trackId": hash, "playing": player["playing"] as? Bool == true, "duration": max(0, min(duration, 86400)),
            "position": max(0, min(position, duration)), "lyricsState": "loading", "lines": [JSONObject]()]
}

final class NativeMusic {
    private let lock = NSLock(), commandLock = NSLock()
    private var value: JSONObject = ["state": "offline"], received = 0.0, enabled = true
    private var cache: [String: (Date, String, [JSONObject])] = [:], loading = Set<String>()
    private var completed = [String: Bool](), order = [String]()
    func setEnabled(_ next: Bool) { lock.lock(); enabled = next; if !next { value = ["state": "offline"] }; lock.unlock() }
    func isEnabled() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func snapshot() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        guard enabled && ProcessInfo.processInfo.systemUptime - received <= 8 else { return ["state": "offline"] }
        var result = value
        if result["state"] as? String == "ready", result["playing"] as? Bool == true {
            result["position"] = min(number(result["duration"]) ?? 0, (number(result["position"]) ?? 0) + ProcessInfo.processInfo.systemUptime - received)
        }
        return result
    }
    func update(_ track: JSONObject) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        var next = track
        if let id = track["trackId"] as? String {
            if let cached = cache[id] { next["lyricsState"] = cached.1; next["lines"] = cached.2 }
            if !loading.contains(id) && (cache[id] == nil || (cache[id]!.1 == "error" && Date().timeIntervalSince(cache[id]!.0) >= 60)) {
                loading.insert(id)
                DispatchQueue.global().async {
                    let result = Result { try findLyrics(track) }
                    self.lock.lock(); defer { self.lock.unlock() }
                    switch result {
                    case .success(let lines): self.cache[id] = (Date(), lines.isEmpty ? "missing" : "ready", lines)
                    case .failure: self.cache[id] = (Date(), "error", [])
                    }
                    self.loading.remove(id)
                    if self.cache.count > 32, let oldest = self.cache.min(by: { $0.value.0 < $1.value.0 })?.key { self.cache.removeValue(forKey: oldest) }
                }
            }
        }
        value = next; received = ProcessInfo.processInfo.systemUptime
    }
    func control(_ command: JSONObject, started: Double = ProcessInfo.processInfo.systemUptime) -> JSONObject {
        commandLock.lock(); defer { commandLock.unlock() }
        let requestID = command["requestId"] as? String ?? UUID().uuidString.lowercased()
        if let success = completed[requestID] { return ["ok": success, "snapshot": snapshot()] }
        let action = command["action"] as? String ?? "", track = command["trackId"] as? String ?? ""
        let seconds = number(command["expiresIn"]) ?? 8, deadline = started + seconds
        guard ["previous", "next", "play", "pause", "replay"].contains(action), track.count == 64,
              seconds > 0 && seconds <= 8, isEnabled(), ProcessInfo.processInfo.systemUptime < deadline,
              let before = try? readPlayer(), before["trackId"] as? String == track else { return ["ok": false, "error": "unavailable"] }
        var success = false
        do {
            let args = ["previous": ["send", "5"], "next": ["send", "4"], "play": ["send", "0"], "pause": ["send", "1"], "replay": ["seek", "0"]]
            _ = try media(args[action]!)
            if action == "replay" {
                guard (try readPlayer())["trackId"] as? String == track, ProcessInfo.processInfo.systemUptime < deadline else { throw ControlError("歌曲已切换") }
                _ = try media(["send", "0"])
            }
            let until = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
            while ProcessInfo.processInfo.systemUptime < until {
                let current = try readPlayer(), same = current["trackId"] as? String == track
                if current["state"] as? String == "ready" &&
                    ((["previous", "next"].contains(action) && !same) || (same &&
                    ((action == "play" && current["playing"] as? Bool == true) || (action == "pause" && current["playing"] as? Bool == false) ||
                    (action == "replay" && current["playing"] as? Bool == true && (number(current["position"]) ?? 100) < 3)))) {
                    update(current); success = true; break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } catch { }
        completed[requestID] = success; order.append(requestID)
        if order.count > 64 { completed.removeValue(forKey: order.removeFirst()) }
        return ["ok": success, "error": success ? NSNull() : "unconfirmed", "snapshot": snapshot()]
    }
    func run() {
        while true {
            let start = ProcessInfo.processInfo.systemUptime
            if isEnabled() { update((try? readPlayer()) ?? ["state": "unavailable"]) }
            Thread.sleep(forTimeInterval: max(0, 0.25 - (ProcessInfo.processInfo.systemUptime - start)))
        }
    }
    func publish() {
        while true {
            let started = ProcessInfo.processInfo.systemUptime
            if isEnabled() {
                do {
                    let token = try displayToken()
                    let url = URL(string: "https://ipad.iamxg.com/api/music")!
                    let response = try HTTPFetch.request(url, token: token, body: snapshot(), timeout: 4) as? JSONObject
                    if let command = response?["command"] as? JSONObject, let id = command["requestId"] as? String {
                        let result = control(command, started: started)
                        var next = snapshot(); next["ack"] = ["requestId": id, "ok": result["ok"] as? Bool == true]
                        _ = try HTTPFetch.request(url, token: token, body: next, timeout: 4)
                    }
                } catch { }
            }
            Thread.sleep(forTimeInterval: max(0, 0.25 - (ProcessInfo.processInfo.systemUptime - started)))
        }
    }
}

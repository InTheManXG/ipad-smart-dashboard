import Foundation

func userAgentSummary(_ ua: String) -> String {
    guard !ua.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "尚未上报设备信息" }
    let system: String
    if ua.contains("iPad") { system = "iPad · iPadOS" }
    else if ua.contains("iPhone") { system = "iPhone · iOS" }
    else if ua.contains("Android") { system = "Android" }
    else if ua.contains("Windows NT") { system = "Windows" }
    else if ua.contains("Macintosh") { system = "Mac / iPad（桌面模式）" }
    else if ua.contains("Linux") { system = "Linux" }
    else { system = "未知设备" }

    // 衍生浏览器也带 Chrome/Safari 标识，优先识别；UA 不能可靠区分桌面模式 iPad 与 Mac。
    let browsers = [("EdgiOS/", "Edge"), ("EdgA/", "Edge"), ("Edg/", "Edge"),
                    ("OPR/", "Opera"), ("FxiOS/", "Firefox"), ("Firefox/", "Firefox"),
                    ("CriOS/", "Chrome"), ("Chrome/", "Chrome")]
    for (marker, name) in browsers {
        if let range = ua.range(of: marker) {
            let major = ua[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
            return system + " · " + name + (major.isEmpty ? "" : " " + major)
        }
    }
    if ua.contains("Safari/"), let range = ua.range(of: "Version/") {
        let major = ua[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return system + " · Safari" + (major.isEmpty ? "" : " " + major)
    }
    return system + " · 未知浏览器"
}

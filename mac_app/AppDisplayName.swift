import Foundation

func appDisplayName(_ path: String) -> String {
    // 访达使用系统本地化显示名，磁盘上的包名可能仍是英文或旧名称。
    let name = FileManager.default.displayName(atPath: path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}

import AppKit

@MainActor private final class DockTestWindow: NSWindow {
    var visibleForTest = false
    var miniaturizedForTest = false
    var sheetForTest = false
    override var isVisible: Bool { visibleForTest }
    override var isMiniaturized: Bool { miniaturizedForTest }
    override var isSheet: Bool { sheetForTest }
}

@main struct WindowDockStateTests {
    struct Failure: Error { let message: String }
    @MainActor static var checks = 0

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
        checks += 1
    }

    @MainActor static func main() throws {
        // 测试只替换窗口状态，不将真实窗口显示到用户桌面。
        NSApplication.shared.setActivationPolicy(.prohibited)
        let main = DockTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let about = DockTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let menu = DockTestWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        main.title = "iPad 控制台"
        about.title = "关于 iPad 控制台"

        try check(!WindowDockState.keepsDock(main), "不可见且未最小化的窗口不保留 Dock")
        main.visibleForTest = true
        try check(WindowDockState.keepsDock(main), "可见主窗口保留 Dock")
        try check(!WindowDockState.keepsDock(main, closing: main), "关闭通知期间排除仍报告可见的当前窗口")
        try check(WindowDockState.keepsDock(main, closing: about), "关闭其他窗口不影响可见主窗口")
        main.visibleForTest = false
        main.miniaturizedForTest = true
        try check(WindowDockState.keepsDock(main), "最小化窗口仍需 Dock 恢复入口")
        try check(!WindowDockState.keepsDock(main, closing: main), "关闭最小化窗口也从统计中排除")
        main.visibleForTest = true
        main.sheetForTest = true
        try check(!WindowDockState.keepsDock(main), "工作表不单独保留 Dock")
        main.sheetForTest = false
        about.visibleForTest = true
        try check(WindowDockState.keepsDock(about), "独立关于或更新窗口保留 Dock")
        menu.visibleForTest = true
        try check(!WindowDockState.keepsDock(menu), "无标题菜单弹层不保留 Dock")
        menu.miniaturizedForTest = true
        try check(!WindowDockState.keepsDock(menu), "窗口状态不能使无标题弹层成为管理窗口")

        try check(WindowDockState.isMainWindow(main), "主窗口标题可识别")
        try check(!WindowDockState.isMainWindow(about), "关于窗口不当成启动时应隐藏的主窗口")
        about.identifier = NSUserInterfaceItemIdentifier("main")
        try check(WindowDockState.isMainWindow(about), "主窗口标识优先于展示标题")
        about.identifier = NSUserInterfaceItemIdentifier("main-extra")
        try check(!WindowDockState.isMainWindow(about), "相似标识不误识别为主窗口")
        about.identifier = NSUserInterfaceItemIdentifier("Main")
        try check(!WindowDockState.isMainWindow(about), "主窗口标识精确匹配")
        main.identifier = NSUserInterfaceItemIdentifier("other")
        try check(WindowDockState.isMainWindow(main), "标识不同仍可用固定主窗口标题识别")
        print("Dock 窗口分类 \(checks) 项检查通过：可见、最小化、关闭、工作表、菜单与主窗口识别")
    }
}

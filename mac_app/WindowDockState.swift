import AppKit

@MainActor final class WindowDockState: NSObject {
    static let shared = WindowDockState()
    var openMainWindow: (() -> Void)?
    private var backgroundLaunch = false
    private let closingWindows = NSHashTable<NSWindow>.weakObjects()

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didUpdateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    func start(inBackground: Bool) {
        backgroundLaunch = inBackground
        if inBackground {
            NSApp.setActivationPolicy(.accessory)
            // SwiftUI 可能在启动回调之后才创建主窗口，通知和下一轮事件循环都要覆盖。
            DispatchQueue.main.async { [weak self] in
                guard self?.backgroundLaunch == true else { return }
                NSApp.windows.filter(Self.isMainWindow).forEach { $0.orderOut(nil) }
            }
        }
    }

    func prepareToOpen() {
        backgroundLaunch = false
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    func reopenMainWindow() {
        prepareToOpen()
        // 后台启动时内容可能尚未 onAppear，已有的隐藏窗口可以直接恢复。
        if let window = NSApp.windows.first(where: Self.isMainWindow) { window.makeKeyAndOrderFront(nil) }
        else { openMainWindow?() }
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "main" || window.title == "iPad 控制台"
    }

    static func keepsDock(_ window: NSWindow, closing: NSWindow? = nil) -> Bool {
        // 菜单栏弹层、工作表不单独占 Dock；最小化的窗口仍需要 Dock 来恢复。
        window !== closing && !window.isSheet && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.keepsDock(window) else { return }
        if notification.name == NSWindow.didBecomeKeyNotification { closingWindows.remove(window) }
        guard !closingWindows.contains(window) else { return }
        if backgroundLaunch && Self.isMainWindow(window) { window.orderOut(nil); return }
        prepareToOpen()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        closingWindows.add(window)
        // willClose 时窗口仍可能报告可见，必须排除它再判断是否还存在其他窗口。
        if !NSApp.windows.contains(where: { !closingWindows.contains($0) && Self.keepsDock($0, closing: window) }) {
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

import AppKit
import Sparkle
import SwiftUI

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheck = false
    @Published private(set) var lastChecked: Date?
    @Published var automaticChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleGetInfoString") as? String ?? "未知" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知" }

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheck = change.newValue ?? false }
        }
        controller.startUpdater()
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        lastChecked = controller.updater.lastUpdateCheckDate
        // 启动及定时检查只在发现新版时提示；没有更新时不打扰用户。
        if automaticChecks {
            status = "正在检查新版本…"
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func check() {
        guard let updater = controller?.updater, updater.canCheckForUpdates else { return }
        status = "正在检查新版本…"
        // 手动检查允许重新显示被跳过的版本，也可唤回正在进行的更新窗口。
        updater.checkForUpdates()
    }

    func install() {
        // 下载、验签和原子替换均交给 Sparkle，沿用 App 退出时停止后台的流程。
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = "发现新版本 \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        status = "当前已是最新版本"
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = "正在下载 \(item.displayVersionString)…"
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) { status = "正在校验并解压更新…" }
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { status = "更新已准备好，等待安装并重启" }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { status = "正在安装更新…" }
    func userDidCancelDownload(_ updater: SPUUpdater) { status = "下载已取消，可以稍后重试" }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastChecked = updater.lastUpdateCheckDate
        if let error = error as NSError?, error.code != SUError.noUpdateError.rawValue {
            status = "更新失败：\(error.localizedDescription)"
        }
    }
}

struct AboutView: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 6) {
                    Text("iPad 控制台").font(.title.bold())
                    Text("版本 \(updater.version)（\(updater.build)）").foregroundStyle(.secondary).textSelection(.enabled)
                    Text("连接你的 Mac 与网页看板").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Label(updater.status, systemImage: updater.availableVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                        .font(.headline).textSelection(.enabled)
                    if let lastChecked = updater.lastChecked {
                        Text("上次检查：\(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if updater.availableVersion != nil {
                            Button("更新并重启…") { updater.install() }.buttonStyle(.borderedProminent).disabled(!updater.canCheck)
                        }
                        Button("检查更新") { updater.check() }.disabled(!updater.canCheck)
                    }
                    Toggle("自动检查正式发行版", isOn: $updater.automaticChecks)
                    Text("发现新版本时提示；确认安装后自动替换并重新启动。配置、Key 和配对会保留。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 20) {
                Link("GitHub 项目", destination: URL(string: "https://github.com/InTheManXG/ipad-smart-dashboard")!)
                Link("发行记录", destination: URL(string: "https://github.com/InTheManXG/ipad-smart-dashboard/releases")!)
            }
            Text("开源软件 · MIT License").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { updater.start() }
    }
}

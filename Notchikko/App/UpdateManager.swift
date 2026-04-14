import Sparkle

/// Sparkle 自动更新管理器
final class UpdateManager {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 启动更新检查（在 applicationDidFinishLaunching 后调用）
    func start() {
        do {
            try updaterController.updater.start()
        } catch {
            Log("Sparkle updater failed to start: \(error)", tag: "Update")
        }
    }

    /// 手动检查更新
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// 是否允许检查更新（供菜单项启用/禁用）
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}

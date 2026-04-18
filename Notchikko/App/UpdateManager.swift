import Sparkle

/// Sparkle 自动更新管理器
final class UpdateManager {
    /// 共享实例。AppDelegate + 设置-关于页都通过它调 `checkForUpdates`，无需通过回调层层传递。
    /// Sparkle 的 updater 在 `start()` 调用前是空转的，预先持有实例是安全的。
    static let shared = UpdateManager()

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

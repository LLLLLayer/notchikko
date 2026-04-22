import SwiftUI

@main
struct NotchikkoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 必须在任何 String(localized:) / NSLocalizedString 解析之前
        applyAppLanguageFromDisk()
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

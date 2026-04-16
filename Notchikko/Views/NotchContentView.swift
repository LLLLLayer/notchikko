import SwiftUI

struct NotchContentView: View {
    let notchHeight: CGFloat
    var sessionManager: SessionManager
    var petSize: CGFloat = 80

    var body: some View {
        ZStack(alignment: .top) {
            // 底层：弹幕（工具名飘过宠物背后）
            if PreferencesStore.shared.preferences.danmakuEnabled {
                DanmakuView(sessionManager: sessionManager)
                    .frame(height: petSize * 0.5)
                    .offset(y: petSize * 0.28)
            }

            // 上层：宠物居中贴在 panel 顶部，上半身自然藏在 notch 里
            NotchikkoRepresentable(state: sessionManager.currentState)
                .frame(width: petSize, height: petSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchikkoRepresentable: NSViewRepresentable {
    let state: NotchikkoState

    func makeNSView(context: Context) -> NotchikkoView {
        let view = NotchikkoView(frame: .zero)
        view.loadSVG(for: state)
        return view
    }

    func updateNSView(_ nsView: NotchikkoView, context: Context) {
        nsView.loadSVG(for: state)
    }
}

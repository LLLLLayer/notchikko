import SwiftUI

struct NotchContentView: View {
    let notchHeight: CGFloat
    var sessionManager: SessionManager
    var petSize: CGFloat = 80

    var body: some View {
        // 宠物居中贴在 panel 顶部，上半身自然藏在 notch 里
        NotchikkoRepresentable(state: sessionManager.currentState)
            .frame(width: petSize, height: petSize)
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

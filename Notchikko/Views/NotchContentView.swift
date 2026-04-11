import SwiftUI

struct NotchContentView: View {
    let notchHeight: CGFloat
    var sessionManager: SessionManager
    var petSize: CGFloat = 80

    var body: some View {
        ZStack(alignment: .top) {
            Color.green.opacity(0.3)  // DEBUG: panel 区域

            NotchikkoRepresentable(svgName: sessionManager.currentState.svgName)
                .frame(width: petSize, height: petSize)
                .background(Color.red.opacity(0.3))  // DEBUG: SVG view 区域
        }
    }
}

struct NotchikkoRepresentable: NSViewRepresentable {
    let svgName: String

    func makeNSView(context: Context) -> NotchikkoView {
        let view = NotchikkoView(frame: .zero)
        view.loadSVG(named: svgName)
        return view
    }

    func updateNSView(_ nsView: NotchikkoView, context: Context) {
        nsView.loadSVG(named: svgName)
    }
}

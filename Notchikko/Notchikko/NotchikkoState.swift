import Foundation

enum NotchikkoState: String, CaseIterable {
    case sleeping
    case idle
    case thinking
    case reading
    case typing
    case building
    case sweeping
    case happy
    case error
    case dragging

    var svgName: String {
        switch self {
        case .sleeping: "clawd-sleeping"
        case .idle: "clawd-idle"
        case .thinking: "clawd-working-thinking"
        case .reading: "clawd-working-typing"
        case .typing: "clawd-working-typing"
        case .building: "clawd-working-building"
        case .sweeping: "clawd-working-sweeping"
        case .happy: "clawd-happy"
        case .error: "clawd-error"
        case .dragging: "clawd-react-drag"
        }
    }

    var revealAmount: CGFloat {
        switch self {
        case .sleeping: 0.05
        case .idle: 0.30
        case .thinking: 0.40
        case .reading: 0.40
        case .typing: 0.50
        case .building: 0.50
        case .sweeping: 0.45
        case .happy: 0.60
        case .error: 0.50
        case .dragging: 1.0
        }
    }

    var priority: Int {
        switch self {
        case .dragging: 100
        case .error: 90
        case .happy: 80
        case .building: 70
        case .typing: 60
        case .reading: 55
        case .sweeping: 53
        case .thinking: 50
        case .idle: 20
        case .sleeping: 10
        }
    }
}

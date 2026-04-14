import SwiftUI

/// 工具类别颜色（ApprovalCardView 和 DanmakuView 共用）
enum ToolColors {
    static func color(for tool: String) -> Color {
        switch tool {
        case "Bash": Color(red: 0.13, green: 0.77, blue: 0.37)
        case "Edit", "Write", "NotebookEdit": Color(red: 0.23, green: 0.51, blue: 0.96)
        case "Read", "Grep", "Glob": Color(red: 0.66, green: 0.33, blue: 0.97)
        default: .orange
        }
    }
}

import Foundation

/// Hook 脚本发来的原始 JSON（所有 CLI 共用同一格式）
struct HookEvent: Decodable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let tool: String?
    let toolInput: [String: AnyCodableValue]?
    let source: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, tool, source
        case toolInput = "tool_input"
        case requestId = "request_id"
    }
}

/// JSON 中任意值的包装
enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else { self = .null }
    }
}

/// 统一事件模型（多 Agent 通用）
enum AgentEvent {
    case sessionStart(sessionId: String, cwd: String, source: String)
    case sessionEnd(sessionId: String)
    case prompt(sessionId: String)
    case toolUse(sessionId: String, tool: String, phase: ToolPhase)
    case notification(sessionId: String, message: String)
    case compact(sessionId: String)
    case stop(sessionId: String)
    case error(sessionId: String, message: String)
}

enum ToolPhase {
    case pre
    case post(success: Bool)
}

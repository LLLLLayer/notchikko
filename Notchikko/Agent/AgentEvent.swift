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
    let prompt: String?          // v0.3: 用户 prompt 文本
    let terminalPid: Int?        // v0.3: 终端进程 PID（hook 进程树检测）
    let terminalTty: String?     // v0.3: 终端 tty 路径（用于 iTerm2 tab 定位）
    let permissionMode: String?  // "default" / "bypassPermissions" 等
    let pidChain: [Int]?         // v0.4: hook→终端的 PID 链（VS Code 终端定位）


    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, tool, source, prompt
        case toolInput = "tool_input"
        case requestId = "request_id"
        case terminalPid = "terminal_pid"
        case terminalTty = "terminal_tty"
        case permissionMode = "permission_mode"
        case pidChain = "pid_chain"
    }
}

/// JSON 中任意值的包装（支持嵌套数组和对象）
enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v) }
        else { self = .null }
    }

    /// 提取字符串值
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// 统一事件模型（多 Agent 通用）
enum AgentEvent {
    case sessionStart(sessionId: String, cwd: String, source: String, terminalPid: Int?, pidChain: [Int]?)
    case sessionEnd(sessionId: String)
    case prompt(sessionId: String, text: String?)
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

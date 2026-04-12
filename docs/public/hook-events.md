# Notchikko Hook Events

Notchikko 通过 Claude Code / Codex 的 Hook 机制接收 Agent 事件，驱动螃蟹 Clawd 的动画状态切换。

## 架构

```
CLI (Claude Code / Codex)
  │  hook 触发
  ▼
notchikko-hook.sh [source]
  │  读取 stdin JSON，转换为统一格式
  ▼
Unix Socket (/tmp/notchikko.sock)
  │
  ▼
Notchikko App (SocketServer → Adapter → SessionManager)
  │
  ▼
Clawd 动画状态切换
```

## 事件列表

| Hook 事件 | 触发时机 | Clawd 状态 | SVG 动画 | 说明 |
|---|---|---|---|---|
| `SessionStart` | 新会话开始 | `idle` | `clawd-idle` | 创建 session，螃蟹醒来 |
| `SessionEnd` | 会话结束 | `sleeping` | `clawd-sleeping` | 清理 session，螃蟹入睡 |
| `UserPromptSubmit` | 用户发送消息 | `thinking` | `clawd-prompt` | 螃蟹开始思考 |
| `PreToolUse` | 工具调用前 | `reading` / `typing` / `building` | `clawd-tool-edit` / `clawd-tool-bash` | 根据工具类型切换动画（见下方映射） |
| `PostToolUse` | 工具调用成功后 | `thinking` | `clawd-prompt` | 回到思考状态 |
| `PostToolUseFailure` | 工具调用失败后 | `error` | `clawd-error` | 螃蟹显示错误状态，5 秒后恢复 |
| `PreCompact` | 上下文压缩前 | `sweeping` | `clawd-compact` | 螃蟹扫地动画 |
| `PostCompact` | 上下文压缩后 | `thinking` | `clawd-prompt` | 回到思考状态 |
| `Stop` | Agent 正常停止 | `happy` | `clawd-stop` | 螃蟹开心动画，3 秒后回到 idle |
| `StopFailure` | Agent 异常停止 | `error` | `clawd-error` | 螃蟹错误状态，5 秒后恢复 |
| `SubagentStart` | 子 Agent 启动 | `thinking` | `clawd-prompt` | 视为继续处理 |
| `SubagentStop` | 子 Agent 完成 | `happy` | `clawd-stop` | 视为一次完成 |
| `Notification` | 通知消息 | (不改变状态) | - | 仅记录事件 |
| `Elicitation` | Agent 请求用户输入 | (不改变状态) | - | 仅记录事件 |
| `WorktreeCreate` | 创建 Git worktree | `thinking` | `clawd-prompt` | 视为继续处理 |
| `PermissionRequest` | 权限请求 | (不改变状态) | - | 仅记录事件 |

## PreToolUse 工具 → 动画映射

| 工具 | Clawd 状态 | SVG | 描述 |
|---|---|---|---|
| `Read`, `Grep`, `Glob` | `reading` | `clawd-tool-edit` | 螃蟹读文件 |
| `Edit`, `Write`, `NotebookEdit` | `typing` | `clawd-tool-edit` | 螃蟹写代码 |
| `Bash` | `building` | `clawd-tool-bash` | 螃蟹执行命令 |
| 其他工具 | `typing` | `clawd-tool-edit` | 默认写代码动画 |

## 审批流程 (PreToolUse)

对于修改型工具（`Bash`、`Edit`、`Write`、`NotebookEdit`），Notchikko 支持阻塞式审批：

1. Hook 脚本为 PreToolUse 事件生成 `request_id`
2. 通过 socket 发送请求并阻塞等待响应（最长 5 分钟）
3. Notchikko App 弹出审批卡片
4. 用户点击 Allow/Deny（或 `⌘Y` / `⌘N`）
5. App 通过 socket 回写 `{"decision": "allow"}` 或 `{"decision": "deny"}`
6. Hook 脚本输出结果到 stdout，CLI 读取并执行

**自动跳过审批的场景：**
- `~/.claude/settings.json` 中 `skipDangerousModePermissionPrompt: true`（bypass permissions 模式）
- Socket 连接失败或超时（默认放行，不阻塞 CLI）

## Hook 脚本数据格式

### 输入 (stdin)

由 CLI 提供的标准 JSON：

```json
{
  "hook_event_name": "PreToolUse",
  "session_id": "abc-123",
  "cwd": "/Users/dev/project",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test"
  }
}
```

### 输出到 Socket

Hook 脚本转换后发送给 Notchikko App：

```json
{
  "session_id": "abc-123",
  "cwd": "/Users/dev/project",
  "event": "PreToolUse",
  "status": "running_tool",
  "tool": "Bash",
  "tool_input": { "command": "npm test" },
  "source": "claude-code",
  "request_id": "uuid-for-approval"
}
```

### 审批响应 (stdout)

仅 PreToolUse 修改型工具会输出：

```json
{"decision": "allow"}
```

或

```json
{"decision": "deny", "reason": "User denied"}
```

## 安装方式

通过 Notchikko 设置面板 → CLI 集成 → 一键安装，自动向 `~/.claude/settings.json` 注册所有 16 个事件的 hook 配置。

Hook 脚本安装位置：`~/.notchikko/hooks/notchikko-hook.sh`

### 手动安装

在 `~/.claude/settings.json` 的 `hooks` 中为每个事件添加：

```json
{
  "hooks": [
    {
      "type": "command",
      "command": "~/.notchikko/hooks/notchikko-hook.sh claude-code"
    }
  ]
}
```

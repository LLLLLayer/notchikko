#!/usr/bin/env python3
# notchikko-hook-version: 4
"""
Notchikko Hook — forwards CLI agent events via Unix socket.

Usage: notchikko-hook.py [source]
  source: "claude-code", "codex", "gemini-cli", "trae-cli" (default: "unknown")

Called by notchikko-hook.sh thin wrapper. Reads the agent's JSON event on
stdin, normalizes per-agent schema differences, and sends to /tmp/notchikko.sock.

For PermissionRequest on approval tools (Bash/Edit/Write/NotebookEdit) or
AskUserQuestion, blocks waiting for the app's decision response.

Fail-open by design: any exception → exit 0 so the hook never blocks the CLI.

Logs each invocation to ~/Library/Logs/Notchikko/hook-YYYY-MM-DD.log
(shared dir with the app; the app's FileLogger purges files >3 days old).
Line format mirrors the app:
    YYYY-MM-DD HH:mm:ss.SSS LEVEL [Hook] sid=xxxxxxxx req=xxxxxxxx k=v ... message
so you can `grep 'sid=abc12345' ~/Library/Logs/Notchikko/*.log` across both ends.
"""
import json
import os
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime


SOCKET_PATH = "/tmp/notchikko.sock"
LOG_DIR = os.path.expanduser("~/Library/Logs/Notchikko")

# 已知终端进程名 → 可匹配的关键词
KNOWN_TERMINALS = {
    "iTerm2", "iTermServer", "Terminal", "Ghostty", "ghostty",
    "Alacritty", "alacritty", "kitty", "WezTerm", "wezterm-gui",
    "Warp", "Hyper",
    "Code Helper", "Cursor Helper",  # VSCode/Cursor 的终端进程
}


def hook_log(level, message, **fields):
    """追加一行日志到 ~/Library/Logs/Notchikko/hook-YYYY-MM-DD.log。
    Fail-silent：任何异常都吞掉，绝不阻塞 hook。

    格式与 Swift FileLogger 对齐：
      YYYY-MM-DD HH:mm:ss.SSS LEVEL [Hook] sid=xxxxxxxx req=xxxxxxxx k=v ... message
    sid/req 取前 8 位，保证和 app 侧日志可以用同一 grep 查到。
    """
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        now = datetime.now()
        ts = now.strftime("%Y-%m-%d %H:%M:%S.") + f"{now.microsecond // 1000:03d}"
        today = now.strftime("%Y-%m-%d")
        path = os.path.join(LOG_DIR, f"hook-{today}.log")

        parts = [ts, level, "[Hook]"]
        sid = fields.pop("sid", None)
        req = fields.pop("req", None)
        if sid:
            parts.append(f"sid={str(sid).split('-', 1)[0][:8]}")
        if req:
            parts.append(f"req={str(req).split('-', 1)[0][:8]}")
        for k, v in fields.items():
            if v is None or v == "":
                continue
            sv = str(v).replace("\n", " ").replace("\r", " ")
            if len(sv) > 200:
                sv = sv[:200] + "..."
            parts.append(f"{k}={sv}")
        parts.append(str(message))
        with open(path, "a", encoding="utf-8") as f:
            f.write(" ".join(parts) + "\n")
    except Exception:
        pass


def detect_terminal_info():
    """沿进程树向上查找终端应用的 PID，并收集中间 PID 链（用于 VS Code 终端定位）"""
    chain = []
    terminal_pid = None
    try:
        pid = os.getppid()
        for _ in range(15):
            if pid <= 1:
                break
            chain.append(pid)
            result = subprocess.run(
                ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode != 0:
                break
            parts = result.stdout.strip().split(None, 1)
            if len(parts) < 2:
                break
            ppid_str, comm = parts
            proc_name = comm.rsplit("/", 1)[-1]
            for term in KNOWN_TERMINALS:
                if term in proc_name:
                    return pid, chain
            pid = int(ppid_str)
    except Exception:
        pass
    return terminal_pid, chain


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    try:
        input_data = json.load(sys.stdin)
    except Exception as e:
        hook_log("ERROR", f"stdin parse failed: {e.__class__.__name__}: {e}", source=source)
        sys.exit(0)

    terminal_pid, pid_chain = detect_terminal_info()

    if source == "trae-cli":
        handle_trae_cli(input_data, source, terminal_pid, pid_chain)
        return

    if source == "gemini-cli":
        normalize_gemini_cli(input_data)

    handle_standard(input_data, source, terminal_pid, pid_chain)


# ============================================================
# Trae CLI (Coco) 适配
# Trae CLI 发送两种格式：
#   新格式（同 Claude Code）: {"hook_event_name": "PreToolUse", "session_id": "...", "tool_name": "...", ...}
#   旧格式（嵌套）: {"event_type": "pre_tool_use", "pre_tool_use": {"cwd": ..., "tool_name": ..., ...}}
# 新格式优先走 handle_standard；旧格式走 handle_trae_cli_legacy 转换后发送。
# 所有事件均为非阻塞（Trae CLI 不读 hook stdout）。
# ============================================================
TRAE_EVENT_MAP = {
    "user_prompt_submit":    ("UserPromptSubmit",   "processing"),
    "pre_tool_use":          ("PreToolUse",         "running_tool"),
    "post_tool_use":         ("PostToolUse",        "processing"),
    "post_tool_use_failure": ("PostToolUseFailure", "error"),
    "stop":                  ("Stop",               "waiting_for_input"),
    "subagent_start":        ("SubagentStart",      "subagent_start"),
    "subagent_stop":         ("SubagentStop",       "subagent_stop"),
    "session_start":         ("SessionStart",       "waiting_for_input"),
    "session_end":           ("SessionEnd",         "ended"),
    "pre_compact":           ("PreCompact",         "compacting"),
    "post_compact":          ("PostCompact",        "processing"),
    "notification":          ("Notification",       "notification"),
    "permission_request":    ("PermissionRequest",  "permission_request"),
}


def handle_trae_cli(input_data, source, terminal_pid, pid_chain):
    # Trae CLI 新版同时提供 hook_event_name（PascalCase，同 Claude Code 格式）
    # 如果有 hook_event_name，走标准路径（但强制非阻塞）
    hook_event_name = input_data.get("hook_event_name", "")
    if hook_event_name and hook_event_name in STATUS_MAP:
        # 确保 session_id 有值（Trae CLI 现在提供了，但 fallback 以防万一）
        if not input_data.get("session_id"):
            input_data["session_id"] = f"trae-{os.getppid()}"
        handle_trae_standard(input_data, source, terminal_pid, pid_chain)
        return

    # 旧格式 fallback：嵌套的 event_type + body
    event_type = input_data.get("event_type", "")
    event_body = input_data.get(event_type, {})

    if event_type not in TRAE_EVENT_MAP:
        hook_log("DEBUG", "trae legacy skip: unknown event_type",
                 source=source, event=event_type)
        sys.exit(0)

    mapped_event, mapped_status = TRAE_EVENT_MAP[event_type]

    # Use real session_id if provided; PPID fallback for older builds
    session_id = event_body.get("session_id", "") or input_data.get("session_id", "") or f"trae-{os.getppid()}"
    cwd = event_body.get("cwd", "") or input_data.get("cwd", "") or os.getcwd()

    output = {
        "session_id": session_id,
        "cwd": cwd,
        "event": mapped_event,
        "status": mapped_status,
        "tool": event_body.get("tool_name", ""),
        "tool_input": event_body.get("tool_input", {}),
        "source": source,
    }

    prompt = event_body.get("prompt", "")
    if prompt:
        output["prompt"] = prompt[:200]

    # notification / permission_request may carry a message
    notification_message = event_body.get("message", "") or input_data.get("message", "")
    if notification_message:
        output["message"] = notification_message[:200]

    # permission_mode if provided
    permission_mode = event_body.get("permission_mode", "") or input_data.get("permission_mode", "")
    if permission_mode:
        output["permission_mode"] = permission_mode

    if terminal_pid:
        output["terminal_pid"] = terminal_pid
    if pid_chain:
        output["pid_chain"] = pid_chain
    try:
        tty = os.ttyname(0)
        if tty:
            output["terminal_tty"] = tty
    except Exception:
        pass

    # Trae CLI 不读 hook stdout，所有事件均为 fire-and-forget
    t0 = time.time()
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(output).encode())
        sock.close()
        hook_log("INFO", "sent", source=source, event=mapped_event, sid=session_id,
                 tool=output["tool"], legacy=1, dur_ms=int((time.time() - t0) * 1000))
    except Exception as e:
        hook_log("ERROR", f"socket error: {e.__class__.__name__}: {e}",
                 source=source, event=mapped_event, sid=session_id, legacy=1)


def handle_trae_standard(input_data, source, terminal_pid, pid_chain):
    """Trae CLI 新格式走标准流程，但强制非阻塞（不生成 request_id，不读 stdout）"""
    hook_event = input_data.get("hook_event_name", "")
    session_id = input_data.get("session_id", "") or f"trae-{os.getppid()}"

    output = {
        "session_id": session_id,
        "cwd": input_data.get("cwd", ""),
        "event": hook_event,
        "status": STATUS_MAP.get(hook_event, "unknown"),
        "tool": input_data.get("tool_name", ""),
        "tool_input": input_data.get("tool_input", {}),
        "source": source,
        "permission_mode": input_data.get("permission_mode", ""),
    }

    prompt_text = input_data.get("prompt", "")
    if prompt_text:
        output["prompt"] = prompt_text[:200]

    notification_message = input_data.get("message", "")
    if notification_message:
        output["message"] = notification_message[:200]

    if terminal_pid:
        output["terminal_pid"] = terminal_pid
    if pid_chain:
        output["pid_chain"] = pid_chain
    try:
        tty = os.ttyname(0)
        if tty:
            output["terminal_tty"] = tty
    except Exception:
        pass

    # 非阻塞：fire-and-forget
    t0 = time.time()
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(output).encode())
        sock.close()
        hook_log("INFO", "sent", source=source, event=hook_event, sid=session_id,
                 tool=output["tool"], dur_ms=int((time.time() - t0) * 1000))
    except Exception as e:
        hook_log("ERROR", f"socket error: {e.__class__.__name__}: {e}",
                 source=source, event=hook_event, sid=session_id)


# ============================================================
# Gemini CLI 适配
# 事件名和工具名均与 Claude Code 不同，规范化到统一 schema 后走标准流程
# ============================================================
GEMINI_EVENT_MAP = {
    "BeforeAgent":  "UserPromptSubmit",
    "BeforeTool":   "PreToolUse",
    "AfterTool":    "PostToolUse",
    "AfterAgent":   "Stop",
    "SessionStart": "SessionStart",
    "SessionEnd":   "SessionEnd",
    "Notification": "Notification",
    "PreCompress":  "PreCompact",
}

# Gemini CLI 使用 snake_case 工具名，映射为 Notchikko 统一的 PascalCase
GEMINI_TOOL_MAP = {
    "read_file":           "Read",
    "read_many_files":     "Read",
    "write_file":          "Write",
    "replace":             "Edit",
    "run_shell_command":   "Bash",
    "glob":                "Glob",
    "grep_search":         "Grep",
    "search_file_content": "Grep",
    "list_directory":      "Glob",
    "ask_user":            "AskUserQuestion",
    "google_web_search":   "WebSearch",
    "web_fetch":           "WebFetch",
}


def normalize_gemini_cli(input_data):
    raw_event = input_data.get("hook_event_name", "")
    mapped = GEMINI_EVENT_MAP.get(raw_event)
    if not mapped:
        hook_log("DEBUG", "gemini skip: unknown event", source="gemini-cli", event=raw_event)
        sys.exit(0)
    input_data["hook_event_name"] = mapped
    raw_tool = input_data.get("tool_name", "")
    if raw_tool in GEMINI_TOOL_MAP:
        input_data["tool_name"] = GEMINI_TOOL_MAP[raw_tool]


# ============================================================
# Claude Code / Codex / (post-normalize) Gemini CLI 标准流程
# ============================================================
STATUS_MAP = {
    "UserPromptSubmit": "processing",
    "PreToolUse": "running_tool",
    "PostToolUse": "processing",
    "PostToolUseFailure": "error",
    "PreCompact": "compacting",
    "PostCompact": "processing",
    "SessionStart": "waiting_for_input",
    "SessionEnd": "ended",
    "Stop": "waiting_for_input",
    "StopFailure": "error",
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
    "Notification": "notification",
    "Elicitation": "elicitation",
    "WorktreeCreate": "worktree_create",
    "PermissionRequest": "permission_request",
}

APPROVAL_TOOLS = {"Bash", "Edit", "Write", "NotebookEdit"}


def read_prefs_approval_enabled():
    """读取 app 的 approvalCardEnabled 开关"""
    try:
        prefs_path = os.path.expanduser("~/Library/Application Support/notchikko/preferences.json")
        with open(prefs_path) as f:
            prefs = json.load(f)
        return prefs.get("approvalCardEnabled", False)
    except Exception:
        return False


def extract_token_usage(transcript_path):
    """Stop 事件：从 transcript 尾部 64KB 提取最后一条 assistant 的 usage"""
    try:
        with open(transcript_path, "rb") as tf:
            tf.seek(0, 2)
            size = tf.tell()
            read_size = min(size, 65536)
            tf.seek(size - read_size)
            tail = tf.read().decode("utf-8", errors="ignore")
        last_usage = None
        for line in tail.strip().split("\n"):
            try:
                entry = json.loads(line)
                if entry.get("type") == "assistant":
                    msg = entry.get("message", {})
                    if "usage" in msg:
                        last_usage = msg["usage"]
            except Exception:
                continue
        if last_usage:
            return {
                "input_tokens": last_usage.get("input_tokens", 0),
                "output_tokens": last_usage.get("output_tokens", 0),
                "cache_read": last_usage.get("cache_read_input_tokens", 0),
                "cache_creation": last_usage.get("cache_creation_input_tokens", 0),
            }
    except Exception:
        pass
    return None


def handle_standard(input_data, source, terminal_pid, pid_chain):
    t0 = time.time()
    hook_event = input_data.get("hook_event_name", "")
    session_id = input_data.get("session_id", "")
    tool_name = input_data.get("tool_name", "")

    if not session_id:
        hook_log("DEBUG", "skip: no session_id", source=source, event=hook_event)
        sys.exit(0)  # 无 session_id 无法处理
    if hook_event not in STATUS_MAP:
        hook_log("DEBUG", "skip: unknown event", source=source, event=hook_event, sid=session_id)
        sys.exit(0)

    # permission_mode：bypassPermissions = --dangerously-skip-permissions
    permission_mode = input_data.get("permission_mode", "default")

    output = {
        "session_id": session_id,
        "cwd": input_data.get("cwd", ""),
        "event": hook_event,
        "status": STATUS_MAP.get(hook_event, "unknown"),
        "tool": tool_name,
        "tool_input": input_data.get("tool_input", {}),
        "source": source,
        "permission_mode": permission_mode,
    }

    # Stop: transcript tail 抽 token 用量
    if hook_event == "Stop":
        transcript_path = input_data.get("transcript_path", "")
        if transcript_path:
            usage = extract_token_usage(transcript_path)
            if usage:
                output["usage"] = usage

    # UserPromptSubmit: 附带 prompt 文本
    prompt_text = input_data.get("prompt", "")
    if prompt_text:
        output["prompt"] = prompt_text[:200]

    # Notification 事件：Claude Code / Gemini CLI 在顶层带 `message` 字段
    # （e.g. "Claude is waiting for your input"）。Gemini 的 Notification 是
    # 它唯一的"attention"信号；Claude Code 也会用它做终端审批 fallback 提示。
    # 转发给 app 在 Adapter 里走 .notification 卡片。
    notification_message = input_data.get("message", "")
    if notification_message:
        output["message"] = notification_message[:200]
    if terminal_pid:
        output["terminal_pid"] = terminal_pid
    if pid_chain:
        output["pid_chain"] = pid_chain
    try:
        tty = os.ttyname(0)
        if tty:
            output["terminal_tty"] = tty
    except Exception:
        pass

    # 审批判定：仅 PermissionRequest 阻塞（PreToolUse 对所有工具都触发，不应阻塞）
    tool_input = input_data.get("tool_input", {})
    bypass = (permission_mode == "bypassPermissions")
    approval_enabled = read_prefs_approval_enabled()

    needs_approval = (hook_event == "PermissionRequest"
                      and tool_name in APPROVAL_TOOLS
                      and approval_enabled
                      and not bypass)
    is_ask_user = (hook_event == "PermissionRequest"
                   and tool_name == "AskUserQuestion"
                   and not bypass)
    needs_blocking = needs_approval or is_ask_user

    request_id = None
    if needs_blocking:
        request_id = str(uuid.uuid4())
        output["request_id"] = request_id

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2 if not needs_blocking else 3600)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(output).encode())

        if needs_blocking:
            hook_log("INFO", "blocking — waiting for decision",
                     source=source, event=hook_event, sid=session_id, req=request_id,
                     tool=tool_name, ask=(1 if is_ask_user else 0))
            handle_blocking_response(sock, tool_input, is_ask_user, source, session_id, request_id)
            hook_log("INFO", "decision complete",
                     source=source, event=hook_event, sid=session_id, req=request_id,
                     dur_ms=int((time.time() - t0) * 1000))
        else:
            hook_log("INFO", "sent",
                     source=source, event=hook_event, sid=session_id, tool=tool_name,
                     dur_ms=int((time.time() - t0) * 1000))
        sock.close()
    except Exception as e:
        hook_log("ERROR", f"socket error: {e.__class__.__name__}: {e}",
                 source=source, event=hook_event, sid=session_id, req=request_id,
                 dur_ms=int((time.time() - t0) * 1000))
        if needs_blocking:
            emit_fallback_allow()
            hook_log("WARN", "emitted fallback allow (socket failed)",
                     source=source, sid=session_id, req=request_id)


def handle_blocking_response(sock, tool_input, is_ask_user, source=None, session_id=None, request_id=None):
    """阻塞等待 app 回写审批决定，打印到 stdout 供 CLI 解析"""
    sock.settimeout(3600)
    response_data = b""
    while True:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                hook_log("WARN", "app closed fd before responding — fallback allow",
                         source=source, sid=session_id, req=request_id)
                emit_fallback_allow()
                return
            response_data += chunk
            try:
                result = json.loads(response_data.decode())
            except json.JSONDecodeError:
                continue

            if is_ask_user:
                answers = result.get("answers", {})
                updated_input = dict(tool_input)
                updated_input["answers"] = answers
                print(json.dumps({"hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "allow",
                        "updatedInput": updated_input,
                    },
                }}))
                hook_log("INFO", "ask-user answered",
                         source=source, sid=session_id, req=request_id,
                         answers=json.dumps(answers)[:100])
            else:
                decision = result.get("decision", "allow")
                decision_obj = {"behavior": decision}
                allow_tool = result.get("allow_tool")
                if allow_tool:
                    # 始终允许：将该工具加入项目允许列表
                    decision_obj["updatedPermissions"] = [{
                        "type": "addRules",
                        "rules": [{"toolName": allow_tool, "ruleContent": "*"}],
                        "behavior": "allow",
                        "destination": "localSettings",
                    }]
                elif result.get("bypass"):
                    # 自动批准：整个 session 切 bypassPermissions
                    decision_obj["updatedPermissions"] = [{
                        "type": "setMode",
                        "mode": "bypassPermissions",
                        "destination": "session",
                    }]
                print(json.dumps({"hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": decision_obj,
                }}))
                hook_log("INFO", f"decision={decision}",
                         source=source, sid=session_id, req=request_id,
                         allow_tool=allow_tool or "",
                         bypass=(1 if result.get("bypass") else 0))
            return
        except socket.timeout:
            hook_log("ERROR", "recv timeout — fallback allow",
                     source=source, sid=session_id, req=request_id)
            emit_fallback_allow()
            return


def emit_fallback_allow():
    """超时 / socket 错误 → 静默放行（fail-open）"""
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {"behavior": "allow"},
    }}))


if __name__ == "__main__":
    main()

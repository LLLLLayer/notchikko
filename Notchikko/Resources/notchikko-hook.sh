#!/bin/bash
# Notchikko Hook — forwards CLI agent events via Unix socket
# Usage: notchikko-hook.sh [source]
#   source: "claude-code", "codex", etc. (default: "unknown")
SOCKET_PATH="/tmp/notchikko.sock"
SOURCE="${1:-unknown}"

# Socket 不存在则静默退出（app 未运行）
[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json, socket, sys, uuid

try:
    input_data = json.load(sys.stdin)
except:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')

status_map = {
    'UserPromptSubmit': 'processing',
    'PreToolUse': 'running_tool',
    'PostToolUse': 'processing',
    'PreCompact': 'compacting',
    'SessionStart': 'waiting_for_input',
    'SessionEnd': 'ended',
    'Stop': 'waiting_for_input',
    'StopFailure': 'error',
    'SubagentStop': 'waiting_for_input',
    'Notification': 'notification',
}

output = {
    'session_id': input_data.get('session_id', ''),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': status_map.get(hook_event, 'unknown'),
    'tool': input_data.get('tool_name', ''),
    'tool_input': input_data.get('tool_input', {}),
    'source': '$SOURCE',
}

# PreToolUse 阻塞模式 — 仅对修改型工具发起审批
approval_tools = {'Bash', 'Edit', 'Write', 'NotebookEdit'}
tool_name = input_data.get('tool_name', '')
needs_approval = hook_event == 'PreToolUse' and tool_name in approval_tools

if needs_approval:
    output['request_id'] = str(uuid.uuid4())

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2 if not needs_approval else 300)  # 审批最长等 5 分钟
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())

    if needs_approval:
        # 等待 app 回写审批结果
        sock.settimeout(300)
        response_data = b''
        while True:
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response_data += chunk
                # 收到完整 JSON 就退出
                try:
                    result = json.loads(response_data.decode())
                    # 输出到 stdout 供 CLI 读取
                    print(json.dumps(result))
                    break
                except json.JSONDecodeError:
                    continue
            except socket.timeout:
                # 超时 — 默认放行
                print(json.dumps({'decision': 'allow'}))
                break
    sock.close()
except:
    if needs_approval:
        # 连接失败 — 默认放行（不阻塞 CLI）
        print(json.dumps({'decision': 'allow'}))
" 2>/dev/null

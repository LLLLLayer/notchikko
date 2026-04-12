#!/bin/bash
# Notchikko Hook — forwards CLI agent events via Unix socket
# Usage: notchikko-hook.sh [source]
#   source: "claude-code", "codex", etc. (default: "unknown")
SOCKET_PATH="/tmp/notchikko.sock"
SOURCE="${1:-unknown}"

# Socket 不存在则静默退出（app 未运行）
[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json, socket, sys, uuid, os

try:
    input_data = json.load(sys.stdin)
except:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')

status_map = {
    'UserPromptSubmit': 'processing',
    'PreToolUse': 'running_tool',
    'PostToolUse': 'processing',
    'PostToolUseFailure': 'error',
    'PreCompact': 'compacting',
    'PostCompact': 'processing',
    'SessionStart': 'waiting_for_input',
    'SessionEnd': 'ended',
    'Stop': 'waiting_for_input',
    'StopFailure': 'error',
    'SubagentStart': 'subagent_start',
    'SubagentStop': 'subagent_stop',
    'Notification': 'notification',
    'Elicitation': 'elicitation',
    'WorktreeCreate': 'worktree_create',
    'PermissionRequest': 'permission_request',
}

if hook_event not in status_map:
    sys.exit(0)

output = {
    'session_id': input_data.get('session_id', ''),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': status_map.get(hook_event, 'unknown'),
    'tool': input_data.get('tool_name', ''),
    'tool_input': input_data.get('tool_input', {}),
    'source': '$SOURCE',
}

# 检查是否开启了 bypass permissions（dangerously skip permissions）
bypass_permissions = False
try:
    settings_path = os.path.expanduser('~/.claude/settings.json')
    with open(settings_path) as f:
        settings = json.load(f)
    bypass_permissions = settings.get('skipDangerousModePermissionPrompt', False)
except:
    pass

# PreToolUse 阻塞审批 — 仅修改型工具 + 未开启 bypass
approval_tools = {'Bash', 'Edit', 'Write', 'NotebookEdit'}
tool_name = input_data.get('tool_name', '')
needs_approval = (hook_event == 'PreToolUse'
                  and tool_name in approval_tools
                  and not bypass_permissions)

if needs_approval:
    output['request_id'] = str(uuid.uuid4())

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2 if not needs_approval else 300)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())

    if needs_approval:
        sock.settimeout(300)
        response_data = b''
        while True:
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response_data += chunk
                try:
                    result = json.loads(response_data.decode())
                    print(json.dumps(result))
                    break
                except json.JSONDecodeError:
                    continue
            except socket.timeout:
                print(json.dumps({'decision': 'allow'}))
                break
    sock.close()
except:
    if needs_approval:
        print(json.dumps({'decision': 'allow'}))
" 2>/dev/null

#!/bin/bash
# Notchikko Hook — forwards Claude Code events via Unix socket
SOCKET_PATH="/tmp/notchikko.sock"

# Socket 不存在则静默退出（app 未运行）
[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json, socket, sys

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
}

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    sock.close()
except:
    pass
" 2>/dev/null

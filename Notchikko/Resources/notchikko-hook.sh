#!/bin/bash
# Notchikko Hook — forwards CLI agent events via Unix socket
# Usage: notchikko-hook.sh [source]
#   source: "claude-code", "codex", "trae-cli", etc. (default: "unknown")
SOCKET_PATH="/tmp/notchikko.sock"
SOURCE="${1:-unknown}"

# Socket 不存在则静默退出（app 未运行）
[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json, socket, sys, uuid, os, subprocess

# 已知终端进程名 → 可匹配的关键词
KNOWN_TERMINALS = {
    'iTerm2', 'iTermServer', 'Terminal', 'Ghostty', 'ghostty',
    'Alacritty', 'alacritty', 'kitty', 'WezTerm', 'wezterm-gui',
    'Warp', 'Hyper',
    'Code Helper', 'Cursor Helper',  # VSCode/Cursor 的终端进程
}

def detect_terminal_info():
    \"\"\"沿进程树向上查找终端应用的 PID，并收集中间 PID 链（用于 VS Code 终端定位）\"\"\"
    chain = []
    terminal_pid = None
    try:
        pid = os.getppid()
        for _ in range(15):
            if pid <= 1:
                break
            chain.append(pid)
            # 获取进程名和父 PID
            result = subprocess.run(
                ['ps', '-o', 'ppid=,comm=', '-p', str(pid)],
                capture_output=True, text=True, timeout=2
            )
            if result.returncode != 0:
                break
            parts = result.stdout.strip().split(None, 1)
            if len(parts) < 2:
                break
            ppid_str, comm = parts
            proc_name = comm.rsplit('/', 1)[-1]  # 取最后一段路径
            # 检查是否是已知终端
            for term in KNOWN_TERMINALS:
                if term in proc_name:
                    terminal_pid = pid
                    return terminal_pid, chain
            pid = int(ppid_str)
    except:
        pass
    return terminal_pid, chain

try:
    input_data = json.load(sys.stdin)
except:
    sys.exit(0)

source = '$SOURCE'
terminal_pid, pid_chain = detect_terminal_info()

# ============================================================
# Trae CLI (Coco) 适配
# Trae CLI 的 JSON 格式与 Claude Code 不同：
#   {'event_type': 'pre_tool_use', 'pre_tool_use': {'cwd': '...', 'tool_name': '...', ...}}
# 需要转换为 Notchikko 统一格式
# ============================================================
if source == 'trae-cli':
    event_type = input_data.get('event_type', '')
    event_body = input_data.get(event_type, {})

    TRAE_EVENT_MAP = {
        'user_prompt_submit': ('UserPromptSubmit', 'processing'),
        'pre_tool_use':       ('PreToolUse',       'running_tool'),
        'post_tool_use':      ('PostToolUse',       'processing'),
        'stop':               ('Stop',              'waiting_for_input'),
        'subagent_stop':      ('SubagentStop',      'subagent_stop'),
    }

    if event_type not in TRAE_EVENT_MAP:
        sys.exit(0)

    mapped_event, mapped_status = TRAE_EVENT_MAP[event_type]

    # Trae CLI 没有 session_id，用 PPID 作为稳定标识
    session_id = 'trae-' + str(os.getppid())
    # cwd 仅 tool 事件有，其余用 os.getcwd() fallback
    cwd = event_body.get('cwd', '') or os.getcwd()

    output = {
        'session_id': session_id,
        'cwd': cwd,
        'event': mapped_event,
        'status': mapped_status,
        'tool': event_body.get('tool_name', ''),
        'tool_input': event_body.get('tool_input', {}),
        'source': source,
    }

    # Trae CLI 的 user_prompt_submit 包含 prompt 文本
    prompt = event_body.get('prompt', '')
    if prompt:
        output['prompt'] = prompt[:200]
    if terminal_pid:
        output['terminal_pid'] = terminal_pid
    if pid_chain:
        output['pid_chain'] = pid_chain
    try:
        tty = os.ttyname(0)
        if tty:
            output['terminal_tty'] = tty
    except:
        pass

    # Trae CLI 不支持审批阻塞，直接发送
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect('$SOCKET_PATH')
        sock.sendall(json.dumps(output).encode())
        sock.close()
    except:
        pass

    sys.exit(0)

# ============================================================
# Gemini CLI 适配
# Gemini CLI 的事件名与 Claude Code 不同，统一映射
# ============================================================
GEMINI_EVENT_MAP = {
    'BeforeAgent':  'UserPromptSubmit',
    'BeforeTool':   'PreToolUse',
    'AfterTool':    'PostToolUse',
    'AfterAgent':   'Stop',
    'SessionStart': 'SessionStart',
    'SessionEnd':   'SessionEnd',
    'Notification': 'Notification',
    'PreCompress':  'PreCompact',
}

# Gemini CLI 使用 snake_case 工具名，映射为 Notchikko 统一的 PascalCase
GEMINI_TOOL_MAP = {
    'read_file':      'Read',
    'read_many_files':'Read',
    'write_file':     'Write',
    'replace':        'Edit',
    'run_shell_command': 'Bash',
    'glob':           'Glob',
    'grep_search':    'Grep',
    'search_file_content': 'Grep',
    'list_directory': 'Glob',
    'ask_user':       'AskUserQuestion',
    'google_web_search': 'WebSearch',
    'web_fetch':      'WebFetch',
}

if source == 'gemini-cli':
    raw_event = input_data.get('hook_event_name', '')
    mapped = GEMINI_EVENT_MAP.get(raw_event)
    if not mapped:
        sys.exit(0)
    input_data['hook_event_name'] = mapped
    # 工具名标准化
    raw_tool = input_data.get('tool_name', '')
    if raw_tool in GEMINI_TOOL_MAP:
        input_data['tool_name'] = GEMINI_TOOL_MAP[raw_tool]

# ============================================================
# Claude Code / Codex / Gemini CLI 标准格式
# ============================================================
hook_event = input_data.get('hook_event_name', '')
if not input_data.get('session_id', ''):
    sys.exit(0)  # 无 session_id 无法处理

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

# 检查 permission_mode（CLI stdin 携带，bypassPermissions = --dangerously-skip-permissions）
permission_mode = input_data.get('permission_mode', 'default')

output = {
    'session_id': input_data.get('session_id', ''),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': status_map.get(hook_event, 'unknown'),
    'tool': input_data.get('tool_name', ''),
    'tool_input': input_data.get('tool_input', {}),
    'source': source,
    'permission_mode': permission_mode,
}

# Stop 事件：从 transcript 文件提取最终 token 用量
if hook_event == 'Stop':
    transcript_path = input_data.get('transcript_path', '')
    if transcript_path:
        try:
            # 从尾部读最后 50 行，找最后一条 assistant 消息的 usage
            with open(transcript_path, 'rb') as tf:
                tf.seek(0, 2)
                size = tf.tell()
                # 读最后 64KB 足够覆盖最后几条消息
                read_size = min(size, 65536)
                tf.seek(size - read_size)
                tail = tf.read().decode('utf-8', errors='ignore')
            last_usage = None
            for line in tail.strip().split('\n'):
                try:
                    entry = json.loads(line)
                    if entry.get('type') == 'assistant':
                        msg = entry.get('message', {})
                        if 'usage' in msg:
                            last_usage = msg['usage']
                except:
                    continue
            if last_usage:
                output['usage'] = {
                    'input_tokens': last_usage.get('input_tokens', 0),
                    'output_tokens': last_usage.get('output_tokens', 0),
                    'cache_read': last_usage.get('cache_read_input_tokens', 0),
                    'cache_creation': last_usage.get('cache_creation_input_tokens', 0),
                }
        except:
            pass

# UserPromptSubmit 事件包含用户 prompt 文本
prompt_text = input_data.get('prompt', '')
if prompt_text:
    output['prompt'] = prompt_text[:200]
if terminal_pid:
    output['terminal_pid'] = terminal_pid
if pid_chain:
    output['pid_chain'] = pid_chain
# 获取当前 tty（用于 iTerm2 多 tab 定位）
try:
    tty = os.ttyname(0)
    if tty:
        output['terminal_tty'] = tty
except:
    pass

# 审批 / AskUserQuestion 判定
approval_tools = {'Bash', 'Edit', 'Write', 'NotebookEdit'}
tool_name = input_data.get('tool_name', '')
tool_input = input_data.get('tool_input', {})
bypass = (permission_mode == 'bypassPermissions')

# 读取 app 的审批开关
approval_enabled = False
try:
    prefs_path = os.path.expanduser('~/Library/Application Support/notchikko/preferences.json')
    with open(prefs_path) as f:
        prefs = json.load(f)
    approval_enabled = prefs.get('approvalCardEnabled', False)
except:
    pass

# 阻塞判定：仅 PermissionRequest 阻塞（Claude Code 真正需要用户确认时才触发）
# PreToolUse 对所有工具都触发，不应阻塞（否则已 allow 的工具也会弹卡）
needs_approval = (hook_event == 'PermissionRequest'
                  and tool_name in approval_tools
                  and approval_enabled
                  and not bypass)

# AskUserQuestion 仅在 PermissionRequest 路径阻塞
is_ask_user = (hook_event == 'PermissionRequest'
               and tool_name == 'AskUserQuestion'
               and not bypass)

needs_blocking = needs_approval or is_ask_user

if needs_blocking:
    output['request_id'] = str(uuid.uuid4())

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2 if not needs_blocking else 3600)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())

    if needs_blocking:
        sock.settimeout(3600)
        response_data = b''
        while True:
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response_data += chunk
                try:
                    result = json.loads(response_data.decode())

                    if is_ask_user:
                        # AskUserQuestion: 回传 questions + answers
                        answers = result.get('answers', {})
                        updated_input = dict(tool_input)
                        updated_input['answers'] = answers
                        print(json.dumps({'hookSpecificOutput': {
                            'hookEventName': 'PermissionRequest',
                            'decision': {
                                'behavior': 'allow',
                                'updatedInput': updated_input,
                            },
                        }}))
                    else:
                        # PermissionRequest 审批
                        decision = result.get('decision', 'allow')
                        decision_obj = {'behavior': decision}
                        allow_tool = result.get('allow_tool')
                        if allow_tool:
                            # 始终允许：将该工具加入项目允许列表
                            decision_obj['updatedPermissions'] = [{
                                'type': 'addRules',
                                'rules': [{'toolName': allow_tool, 'ruleContent': '*'}],
                                'behavior': 'allow',
                                'destination': 'localSettings',
                            }]
                        elif result.get('bypass'):
                            # 自动批准：整个 session 切 bypassPermissions
                            decision_obj['updatedPermissions'] = [{
                                'type': 'setMode',
                                'mode': 'bypassPermissions',
                                'destination': 'session',
                            }]
                        print(json.dumps({'hookSpecificOutput': {
                            'hookEventName': 'PermissionRequest',
                            'decision': decision_obj,
                        }}))
                    break
                except json.JSONDecodeError:
                    continue
            except socket.timeout:
                # 超时自动放行
                print(json.dumps({'hookSpecificOutput': {
                    'hookEventName': 'PermissionRequest',
                    'decision': {'behavior': 'allow'},
                }}))
                break
    sock.close()
except:
    if needs_blocking:
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': {'behavior': 'allow'},
        }}))
" 2>/dev/null

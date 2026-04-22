#!/usr/bin/env python3
"""
claude-stats-gemini-hook.py — Gemini CLI hook for Claude Statistics notch notifications.
Managed by Claude Statistics. Do not edit manually.
"""
import json
import os
import socket
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone

SOCKET_PATH = f"/tmp/claude-stats-attention-{os.getuid()}.sock"
DEBUG_LOG_PATH = f"/tmp/claude-stats-gemini-debug-{os.getuid()}.jsonl"
CONNECT_TIMEOUT = 2.0

RELAYED_EVENTS = {
    "BeforeAgent",
    "BeforeTool",
    "BeforeToolSelection",
    "BeforeModel",
    "AfterTool",
    "AfterModel",
    "AfterAgent",
    "SessionStart",
    "SessionEnd",
    "PreCompress",
    "Notification",
}

TOOL_NAME_MAP = {
    "run_shell_command": "bash",
    "read_file": "read",
    "write_file": "write",
    "replace": "edit",
    "glob": "glob",
    "grep": "grep",
    "web_fetch": "fetch",
    "web_search": "websearch",
}

def utc_timestamp():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

def append_debug(record):
    try:
        os.makedirs(os.path.dirname(DEBUG_LOG_PATH), exist_ok=True)
        record["timestamp"] = utc_timestamp()
        with open(DEBUG_LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass

def record_diagnostic(stage, message, **context):
    append_debug({
        "stage": stage,
        "message": message,
        "context": context,
    })

def is_noise_text(value):
    normalized = (value or "").strip().lower()
    return normalized in {"text", "json", "stdout", "output", "---", "--", "...", "…"}

def first_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        text = value.strip()
        return "" if is_noise_text(text) else text
    if isinstance(value, list):
        for item in value:
            text = first_text(item)
            if text:
                return text
        return ""
    if isinstance(value, dict):
        for key in ("message", "text", "content", "summary", "error", "reason", "warning", "prompt"):
            text = first_text(value.get(key))
            if text:
                return text
        for key, item in value.items():
            if key in {"type", "kind", "status", "role", "mime_type", "content_type"}:
                continue
            text = first_text(item)
            if text:
                return text
        return ""
    return str(value).strip()

def normalize_tty(value):
    if not value or value == "??":
        return ""
    return value if value.startswith("/dev/") else f"/dev/{value}"

def get_tty(pid=None):
    try:
        return normalize_tty(os.ttyname(sys.stdin.fileno()))
    except Exception:
        env_tty = normalize_tty(os.environ.get("TTY", ""))
        if env_tty:
            return env_tty
        if pid:
            try:
                out = subprocess.check_output(
                    ["/bin/ps", "-o", "tty=", "-p", str(pid)],
                    text=True,
                    timeout=0.5,
                ).strip()
                return normalize_tty(out)
            except Exception:
                return ""
        return ""

def normalize_path(value):
    if not value:
        return ""

    text = value.strip()
    if not text:
        return ""

    if text.startswith("file://"):
        try:
            text = urllib.parse.unquote(urllib.parse.urlparse(text).path)
        except Exception:
            text = text[7:]

    try:
        return os.path.realpath(text)
    except Exception:
        return os.path.abspath(text)

def ghostty_frontmost_context(cwd):
    script = """
    tell application id "com.mitchellh.ghostty"
        if not frontmost then return ""
        try
            set w to front window
            set tabRef to selected tab of w
            set terminalRef to focused terminal of tabRef
            set outputLine to (id of w as text) & (ASCII character 31) & (id of tabRef as text) & (ASCII character 31) & (id of terminalRef as text) & (ASCII character 31) & (working directory of terminalRef as text)
            return outputLine
        end try
    end tell
    return ""
    """

    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=1,
        )
    except Exception:
        return {}

    if result.returncode != 0:
        return {}

    parts = result.stdout.strip().split("\x1f")
    if len(parts) != 4:
        return {}

    if normalize_path(parts[3]) != normalize_path(cwd):
        return {}

    return {
        "terminal_window_id": parts[0] or None,
        "terminal_tab_id": parts[1] or None,
        "terminal_surface_id": parts[2] or None,
    }

def get_terminal_context(event_name, terminal_name, cwd):
    normalized = (terminal_name or "").lower()
    if "iterm" in normalized:
        session_id = os.environ.get("ITERM_SESSION_ID") or ""
        stable_id = session_id.split(":", 1)[1] if ":" in session_id else session_id
        return {
            "terminal_surface_id": stable_id or None,
        }

    if "kitty" in normalized:
        return {
            "terminal_socket": os.environ.get("KITTY_LISTEN_ON") or None,
            "terminal_surface_id": os.environ.get("KITTY_WINDOW_ID") or None,
        }

    if "wezterm" in normalized:
        return {
            "terminal_socket": os.environ.get("WEZTERM_UNIX_SOCKET") or None,
            "terminal_surface_id": os.environ.get("WEZTERM_PANE") or None,
        }

    if "ghostty" not in normalized:
        return {}

    if event_name == "BeforeAgent":
        frontmost = ghostty_frontmost_context(cwd)
        if frontmost:
            return frontmost

    return {}

def canonical_tool_name(name):
    if not isinstance(name, str) or not name:
        return ""
    return TOOL_NAME_MAP.get(name, name)

def normalize_tool_input(tool_name, raw_input):
    if not isinstance(raw_input, dict):
        return {}

    normalized = dict(raw_input)
    if tool_name == "edit":
        if "filePath" in normalized and "file_path" not in normalized:
            normalized["file_path"] = normalized["filePath"]
        if "oldString" in normalized and "old_string" not in normalized:
            normalized["old_string"] = normalized["oldString"]
        if "newString" in normalized and "new_string" not in normalized:
            normalized["new_string"] = normalized["newString"]
    elif tool_name in {"read", "write"}:
        if "filePath" in normalized and "file_path" not in normalized:
            normalized["file_path"] = normalized["filePath"]
    elif tool_name == "bash":
        if "command" not in normalized and "cmd" in normalized:
            normalized["command"] = normalized["cmd"]

    return normalized

def notification_tool_details(details):
    if not isinstance(details, dict):
        return "", {}

    details_type = details.get("type")
    title = details.get("title") if isinstance(details.get("title"), str) else ""

    if details_type == "exec":
        return "bash", {
            "command": details.get("command"),
            "description": title or None,
            "root_command": details.get("rootCommand"),
        }
    if details_type == "edit":
        return "edit", {
            "file_path": details.get("filePath"),
            "description": title or None,
        }
    if details_type == "mcp":
        tool_name = details.get("toolName") if isinstance(details.get("toolName"), str) else "mcp"
        return tool_name, {
            "server_name": details.get("serverName"),
            "tool_display_name": details.get("toolDisplayName"),
            "description": title or None,
        }
    if details_type == "info":
        return "info", {
            "prompt": details.get("prompt"),
            "description": title or None,
        }

    return title, {"description": title or None}

def extract_message(payload, event):
    if event == "BeforeAgent":
        return first_text(payload.get("prompt"))
    if event == "BeforeModel":
        return first_text(payload.get("llm_request"))
    if event == "AfterModel":
        return first_text(payload.get("llm_response"))
    if event == "AfterAgent":
        return (
            first_text(payload.get("prompt_response"))
            or first_text(payload.get("prompt"))
            or first_text(payload.get("reason"))
        )
    if event == "SessionStart":
        return first_text(payload.get("source"))
    if event == "SessionEnd":
        return first_text(payload.get("reason"))
    if event == "Notification":
        return first_text(payload.get("message"))
    return (
        first_text(payload.get("message"))
        or first_text(payload.get("reason"))
        or first_text(payload.get("warning"))
    )

def send(payload):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(CONNECT_TIMEOUT)
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())
        s.close()
        append_debug({
            "stage": "socket_sent",
            "event": payload.get("event"),
            "session_id": payload.get("session_id"),
            "socket_path": SOCKET_PATH,
        })
    except Exception as error:
        record_diagnostic(
            "socket_error",
            str(error),
            event=payload.get("event"),
            session_id=payload.get("session_id"),
            socket_path=SOCKET_PATH,
        )

def main():
    try:
        payload = json.loads(sys.stdin.read())
    except Exception as error:
        record_diagnostic("stdin_decode_failed", str(error))
        sys.exit(0)

    event = payload.get("hook_event_name", "")
    if event not in RELAYED_EVENTS:
        append_debug({
            "stage": "event_ignored",
            "event": event,
        })
        sys.exit(0)

    notification_type = payload.get("notification_type")

    session_id = payload.get("session_id", "")
    cwd = payload.get("cwd", "")
    pid = os.getppid()
    tty = get_tty(pid)
    terminal_name = os.environ.get("TERM_PROGRAM") or os.environ.get("TERM")
    terminal_context = get_terminal_context(event, terminal_name, cwd)

    wire_event = event
    tool_name = None
    tool_input = None

    if event == "BeforeAgent":
        wire_event = "UserPromptSubmit"
    elif event == "BeforeTool":
        wire_event = "PreToolUse"
        tool_name = canonical_tool_name(payload.get("tool_name"))
        tool_input = normalize_tool_input(tool_name, payload.get("tool_input"))
    elif event == "BeforeToolSelection":
        wire_event = "BeforeToolSelection"
    elif event == "BeforeModel":
        wire_event = "BeforeModel"
    elif event == "AfterTool":
        wire_event = "PostToolUse"
        tool_name = canonical_tool_name(payload.get("tool_name"))
        tool_input = normalize_tool_input(tool_name, payload.get("tool_input"))
    elif event == "AfterModel":
        wire_event = "AfterModel"
    elif event == "AfterAgent":
        wire_event = "Stop"
    elif event == "Notification" and notification_type == "ToolPermission":
        wire_event = "ToolPermission"
        tool_name, tool_input = notification_tool_details(payload.get("details"))
    elif event == "PreCompress":
        wire_event = "PreCompress"

    status = "processing"
    if wire_event == "ToolPermission":
        status = "waiting_for_approval"
    elif wire_event == "PreToolUse":
        status = "running_tool"
    elif wire_event in {"BeforeToolSelection", "BeforeModel", "AfterModel", "PreCompress"}:
        status = "processing"
    elif wire_event in {"Stop", "SessionStart"}:
        status = "waiting_for_input"
    elif wire_event == "SessionEnd":
        status = "ended"

    msg = {
        "v": 1,
        "provider": "gemini",
        "event": wire_event,
        "status": status,
        "notification_type": notification_type,
        "session_id": session_id,
        "cwd": cwd,
        "pid": pid,
        "tty": tty,
        "terminal_name": terminal_name,
        "terminal_socket": terminal_context.get("terminal_socket"),
        "terminal_window_id": terminal_context.get("terminal_window_id"),
        "terminal_tab_id": terminal_context.get("terminal_tab_id"),
        "terminal_surface_id": terminal_context.get("terminal_surface_id"),
        "transcript_path": payload.get("transcript_path"),
        "tool_name": tool_name or None,
        "tool_input": tool_input or None,
        "tool_use_id": payload.get("tool_use_id"),
        "message": extract_message(payload, event) or None,
        "expects_response": False,
        "timeout_ms": None,
    }

    if event == "AfterTool":
        text = first_text(payload.get("tool_response"))
        if text:
            msg["tool_response"] = text[:1200]

    append_debug({
        "stage": "hook_received",
        "event": event,
        "wire_event": wire_event,
        "session_id": session_id,
        "socket_path": SOCKET_PATH,
        "tty": tty,
        "terminal_name": terminal_name,
        "tool_name": tool_name,
        "notification_type": notification_type,
    })

    send(msg)
    sys.exit(0)

if __name__ == "__main__":
    main()

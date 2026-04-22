#!/usr/bin/env python3
"""
claude-stats-codex-hook.py — Codex hook for Claude Statistics notch notifications.
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
DEBUG_LOG_PATH = os.path.expanduser("~/.codex/hooks/claude-stats-codex-debug.jsonl")
CONNECT_TIMEOUT = 2.0
RECV_TIMEOUT = 280.0

RELAYED_EVENTS = {
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
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
    if not value or value in {"??", "-"}:
        return ""
    return value if value.startswith("/dev/") else f"/dev/{value}"

def get_tty(pid=None):
    if pid:
        try:
            out = subprocess.check_output(
                ["/bin/ps", "-o", "tty=", "-p", str(pid)],
                text=True,
                timeout=0.5,
            ).strip()
            tty = normalize_tty(out)
            if tty:
                return tty
        except Exception:
            pass

    try:
        return normalize_tty(os.ttyname(sys.stdin.fileno()))
    except Exception:
        return normalize_tty(os.environ.get("TTY", ""))

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

    if event_name == "UserPromptSubmit":
        frontmost = ghostty_frontmost_context(cwd)
        if frontmost:
            return frontmost

    return {}

def normalize_tool_input(payload):
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict):
        return tool_name, tool_input

    command = None
    if isinstance(tool_input, str):
        command = tool_input
    if command is None and isinstance(payload.get("command"), str):
        command = payload.get("command")

    if command:
        return tool_name, {"command": command}

    return tool_name, {}

def extract_message(payload, event):
    if event == "UserPromptSubmit":
        return first_text(payload.get("prompt"))
    if event == "SessionStart":
        return first_text(payload.get("source"))
    if event == "Stop":
        return (
            first_text(payload.get("last_assistant_message"))
            or first_text(payload.get("message"))
            or first_text(payload.get("reason"))
            or first_text(payload.get("prompt"))
            or first_text(payload.get("warning"))
        )
    return (
        first_text(payload.get("message"))
        or first_text(payload.get("reason"))
        or first_text(payload.get("warning"))
    )

def send(payload, expects_response=False):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(CONNECT_TIMEOUT)
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())
        if not expects_response:
            s.close()
            append_debug({
                "stage": "socket_sent",
                "event": payload.get("event"),
                "session_id": payload.get("session_id"),
                "expects_response": False,
                "socket_path": SOCKET_PATH,
            })
            return None
        s.settimeout(RECV_TIMEOUT)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        s.close()
        if not buf.strip():
            record_diagnostic(
                "socket_empty_response",
                "Permission request socket closed before response",
                event=payload.get("event"),
                session_id=payload.get("session_id"),
                socket_path=SOCKET_PATH,
            )
            return None
        response = json.loads(buf.strip())
        append_debug({
            "stage": "socket_response",
            "event": payload.get("event"),
            "session_id": payload.get("session_id"),
            "decision": response.get("decision"),
            "socket_path": SOCKET_PATH,
        })
        return response
    except Exception as error:
        record_diagnostic(
            "socket_error",
            str(error),
            event=payload.get("event"),
            session_id=payload.get("session_id"),
            expects_response=expects_response,
            socket_path=SOCKET_PATH,
        )
        return None

def print_permission_decision(decision):
    if decision == "allow":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "allow"
                }
            }
        }))
    elif decision == "deny":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": "Denied via Claude Statistics"
                }
            }
        }))
    else:
        # No decision from the notch: let Codex continue with its native UI.
        print("{}")

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

    session_id = payload.get("session_id", "")
    cwd = payload.get("cwd", "")
    pid = os.getppid()
    terminal_name = os.environ.get("TERM_PROGRAM") or os.environ.get("TERM")
    terminal_context = get_terminal_context(event, terminal_name, cwd)
    tool_name, tool_input = normalize_tool_input(payload)

    if event == "PermissionRequest":
        status = "waiting_for_approval"
    elif event == "SessionStart":
        status = "waiting_for_input"
    elif event == "PreToolUse":
        status = "running_tool"
    elif event == "Stop":
        status = "waiting_for_input"
    else:
        status = "processing"

    msg = {
        "v": 1,
        "provider": "codex",
        "event": event,
        "status": status,
        "notification_type": None,
        "session_id": session_id,
        "cwd": cwd,
        "pid": pid,
        "tty": get_tty(pid),
        "terminal_name": terminal_name,
        "terminal_socket": terminal_context.get("terminal_socket"),
        "terminal_window_id": terminal_context.get("terminal_window_id"),
        "terminal_tab_id": terminal_context.get("terminal_tab_id"),
        "terminal_surface_id": terminal_context.get("terminal_surface_id"),
        "transcript_path": payload.get("transcript_path"),
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_use_id": payload.get("tool_use_id") or payload.get("turn_id"),
        "message": extract_message(payload, event) or None,
        "expects_response": event == "PermissionRequest",
        "timeout_ms": 280000 if event == "PermissionRequest" else None,
    }

    if event == "PostToolUse":
        text = first_text(payload.get("tool_response"))
        if text:
            msg["tool_response"] = text[:1200]

    append_debug({
        "stage": "hook_received",
        "event": event,
        "session_id": session_id,
        "expects_response": msg["expects_response"],
        "socket_path": SOCKET_PATH,
        "tty": msg["tty"],
        "terminal_name": terminal_name,
        "tool_name": tool_name,
    })

    if event == "PermissionRequest":
        response = send(msg, expects_response=True)
        print_permission_decision((response or {}).get("decision"))
        sys.exit(0)

    send(msg, expects_response=False)
    sys.exit(0)

if __name__ == "__main__":
    main()

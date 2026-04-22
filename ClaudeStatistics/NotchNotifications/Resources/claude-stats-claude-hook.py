#!/usr/bin/env python3
"""
claude-stats-claude-hook.py — Claude Code hook for Claude Statistics notch notifications.
Managed by Claude Statistics. Do not edit manually.
"""
import json
import os
import socket
import subprocess
import sys
import urllib.parse

SOCKET_PATH = f"/tmp/claude-stats-attention-{os.getuid()}.sock"
CONNECT_TIMEOUT = 2.0
RECV_TIMEOUT = 300.0

# Events that are relayed to the Claude Statistics app. Events not in this
# list are simply ignored (script exits 0 without contacting the socket) so
# the hook stays silent for noisy events that happen to be registered.
RELAYED_EVENTS = {
    "UserPromptSubmit",    # silent tracking — marks a session as active
    "PreToolUse",          # silent tracking — captures per-session activity
    "PostToolUse",         # silent tracking — captures per-session activity
    "PostToolUseFailure",  # silent tracking — failed tool still means active
    "PermissionRequest",   # critical — bidirectional approval
    "Notification",        # Claude is idle waiting for input
    "Stop",                # task done
    "SessionEnd",          # silent tracking — removes the session from active list
    "SubagentStart",       # silent tracking — active work
    "SubagentStop",        # subagent done
    "StopFailure",         # task failed (rate limit / auth / billing)
    "SessionStart",        # informational — new session started
    "PreCompact",          # silent tracking
    "PostCompact",         # silent tracking
}

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

def is_noise_text(value):
    normalized = (value or "").strip().lower()
    return normalized in {"text", "json", "stdout", "output", "---", "--", "...", "…"}

def extract_preview(payload):
    for key in (
        "message",
        "reason",
        "prompt",
        "warning",
        "error",
        "summary",
        "content",
    ):
        text = first_text(payload.get(key))
        if text:
            return text

    hook_output = payload.get("hookSpecificOutput")
    text = first_text(hook_output)
    if text:
        return text

    return ""

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

    # Only bind a session to the frontmost Ghostty surface at moments that
    # clearly represent user interaction inside that session. Later async hook
    # events (Stop/Notification/etc.) can arrive after the user has switched to
    # another tab in the same cwd, which would otherwise overwrite the mapping.
    if event_name == "UserPromptSubmit":
        frontmost = ghostty_frontmost_context(cwd)
        if frontmost:
            return frontmost

    script = """
    tell application id "com.mitchellh.ghostty"
        set outputLines to {}
        repeat with w in every window
            set windowID to id of w as text
            repeat with tabRef in every tab of w
                set tabID to id of tabRef as text
                set terminalRef to focused terminal of tabRef
                set terminalID to id of terminalRef as text
                set terminalWD to working directory of terminalRef as text
                set end of outputLines to windowID & (ASCII character 31) & tabID & (ASCII character 31) & terminalID & (ASCII character 31) & terminalWD
            end repeat
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to ""
        return outputText
    end tell
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

    normalized_cwd = normalize_path(cwd)
    candidates = []
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split("\x1f")
        if len(parts) != 4:
            continue
        if normalize_path(parts[3]) != normalized_cwd:
            continue
        candidates.append({
            "terminal_window_id": parts[0] or None,
            "terminal_tab_id": parts[1] or None,
            "terminal_surface_id": parts[2] or None,
        })

    if len(candidates) == 1:
        return candidates[0]

    return {}

def send(payload: dict, expects_response: bool):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(CONNECT_TIMEOUT)
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(payload) + "\n").encode())
        if not expects_response:
            s.close()
            return None
        s.settimeout(RECV_TIMEOUT)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        s.close()
        return json.loads(buf.strip())
    except Exception:
        return None

def main():
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)

    event = payload.get("hook_event_name", "")
    if event not in RELAYED_EVENTS:
        sys.exit(0)

    session_id = payload.get("session_id", "")
    cwd        = payload.get("cwd", "")
    pid        = os.getppid()
    tty        = get_tty(pid)
    terminal_name = os.environ.get("TERM_PROGRAM") or os.environ.get("TERM")
    terminal_context = get_terminal_context(event, terminal_name, cwd)
    notification_type = payload.get("notification_type")

    if event == "PermissionRequest":
        status = "waiting_for_approval"
    elif event == "Notification":
        if notification_type == "idle_prompt":
            status = "waiting_for_input"
        elif notification_type == "permission_prompt":
            status = "processing"
        else:
            status = "notification"
    elif event in {"Stop", "StopFailure", "SessionStart"}:
        status = "waiting_for_input"
    elif event == "SessionEnd":
        status = "ended"
    elif event == "PreCompact":
        status = "compacting"
    elif event == "PreToolUse":
        status = "running_tool"
    else:
        status = "processing"

    # Base wire message — per-event handling fills in tool fields and response mode.
    msg = {
        "v": 1,
        "provider": "claude",
        "event": event,
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
        "tool_name": None,
        "tool_input": None,
        "tool_use_id": None,
        "message": extract_preview(payload) or None,
        "expects_response": False,
        "timeout_ms": None,
    }

    if event in {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"}:
        msg["tool_name"] = payload.get("tool_name")
        msg["tool_input"] = payload.get("tool_input")
        msg["tool_use_id"] = payload.get("tool_use_id")

    # Capture tool result for PostToolUse so the active-sessions list can show
    # what the latest background shell / subagent / tool produced. Truncated
    # aggressively because some tool responses (file reads, ls -la) are huge.
    if event in {"PostToolUse", "PostToolUseFailure"}:
        raw_response = payload.get("tool_response")
        text = first_text(raw_response)
        if text:
            msg["tool_response"] = text[:1200]

    if event == "PermissionRequest":
        msg["expects_response"] = True
        msg["timeout_ms"]       = 280000
        response = send(msg, expects_response=True)
        decision = (response or {}).get("decision")
        if decision == "allow":
            print(json.dumps({
                "behavior": "allow",
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "allow"
                    }
                }
            }))
        elif decision == "deny":
            print(json.dumps({
                "behavior": "deny",
                "message": "Denied via Claude Statistics",
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": "Denied via Claude Statistics"
                    }
                }
            }))
        elif decision == "ask":
            # Fall through to Claude Code's native approval UI.
            print("{}")
        sys.exit(0)

    # All other relayed events are fire-and-forget.
    send(msg, expects_response=False)
    sys.exit(0)

if __name__ == "__main__":
    main()

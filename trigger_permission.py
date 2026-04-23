import socket
import json
import os
import sys

def trigger():
    socket_path = f"/tmp/claude-stats-attention-{os.getuid()}.sock"
    if not os.path.exists(socket_path):
        print(f"Error: Socket {socket_path} not found. Is the app running?")
        sys.exit(1)

    message = {
        "provider": "claude",
        "event": "PermissionRequest",
        "tool_name": "bash",
        "tool_input": {"command": "echo 'Hello from Gemini CLI'"},
        "tool_use_id": "gemini-test-uid",
        "session_id": "gemini-test-session",
        "message": "Gemini CLI is testing the permission notch",
        "expects_response": True,
        "timeout_ms": 30000
    }

    print(f"Connecting to {socket_path}...")
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(socket_path)
        print("Sending PermissionRequest...")
        client.sendall((json.dumps(message) + "\n").encode('utf-8'))

        print("Waiting for user decision in the Notch UI...")
        response = client.recv(1024)
        if response:
            print(f"Received response: {response.decode('utf-8').strip()}")
        else:
            print("Connection closed by server (likely timed out or dismissed).")
        client.close()
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    trigger()

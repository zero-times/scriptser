#!/usr/bin/env python3
"""Scriptser same-user local control client. Python 3 standard library only."""
import argparse
import json
import math
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys

APP_TARGET = {{APP_TARGET_JSON}}
BUNDLE_ID = "{{BUNDLE_ID}}"
SUPPORT_NAME = "{{SUPPORT_NAME}}"
MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 32 * 1024 * 1024


def emit(value):
    print(json.dumps(value, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("method", help="status, launch, scripts.list, scripts.run, etc.; see references/cli.md")
    params = parser.add_mutually_exclusive_group()
    params.add_argument("--params", help="JSON object; prefer --params-file for commands or private data")
    params.add_argument("--params-file", help="UTF-8 JSON object file, or - for stdin")
    parser.add_argument("--socket", default=str(Path.home() / "Library/Application Support" / SUPPORT_NAME / "control.sock"))
    parser.add_argument("--timeout", type=float, default=15, help="response timeout in seconds (default: 15)")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    sent = False
    try:
        if args.params_file:
            raw = sys.stdin.read() if args.params_file == "-" else Path(args.params_file).read_text(encoding="utf-8")
        else:
            raw = args.params or "{}"
        values = json.loads(raw)
        if not isinstance(values, dict):
            raise ValueError("params must be a JSON object")
        if args.method == "launch":
            if values:
                raise ValueError("launch takes no parameters")
            target = [APP_TARGET] if APP_TARGET.endswith(".app") else ["-b", BUNDLE_ID]
            subprocess.run(["/usr/bin/open", "-g"] + target, check=True, capture_output=True)
            emit({"ok": True, "result": {"launchRequested": True, "next": "Poll status until startupComplete is true."}})
            return 0
        request = json.dumps({"version": 1, "method": args.method, "params": values}, ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
        if len(request) > MAX_REQUEST:
            raise ValueError("Request exceeds 1 MiB")
        info = os.lstat(args.socket)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("Refusing an unsafe socket: expected same-user socket with mode 0600")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(args.timeout)
            client.connect(args.socket)
            # Once sendall begins, a transport error leaves the mutation outcome uncertain.
            sent = True
            client.sendall(request)
            response = bytearray()
            while b"\n" not in response:
                chunk = client.recv(65536)
                if not chunk:
                    raise ValueError("Connection closed without a complete response")
                response.extend(chunk)
                if len(response) > MAX_RESPONSE:
                    raise ValueError("Response exceeds 32 MiB")
        result = json.loads(bytes(response).split(b"\n", 1)[0])
        if not isinstance(result, dict) or type(result.get("ok")) is not bool:
            raise ValueError("Invalid Scriptser response")
        emit(result)
        return 0 if result["ok"] else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        message = str(error)
        if isinstance(error, (FileNotFoundError, ConnectionRefusedError)) and not sent:
            message = "Scriptser control endpoint is unavailable. Scriptser 1.3.1+ must be running. Use launch explicitly, then poll status. " + message
        if sent:
            message += " Request may have been applied. Inspect status/result before retrying a mutation."
        emit({"ok": False, "error": {"code": "transport_error" if sent else "client_error", "message": message}})
        return 2


if __name__ == "__main__":
    sys.exit(main())

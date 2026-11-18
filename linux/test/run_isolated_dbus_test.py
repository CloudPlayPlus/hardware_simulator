#!/usr/bin/env python3
"""Run a Linux integration test without sharing the desktop's D-Bus sockets."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("pass a test command after --")

    with tempfile.TemporaryDirectory(prefix="cpp-linux-dbus-") as root:
        env = os.environ.copy()
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "AT_SPI_BUS_ADDRESS",
                    "DBUS_SESSION_BUS_ADDRESS", "IBUS_ADDRESS"):
            env.pop(key, None)
        for name in ("RUNTIME", "CACHE", "CONFIG", "DATA", "STATE"):
            path = Path(root, name.lower())
            path.mkdir(mode=0o700)
            env[f"XDG_{name}_DIR" if name == "RUNTIME" else f"XDG_{name}_HOME"] = str(path)

        with subprocess.Popen(["dbus-run-session", "--", *command],
                              env=env, start_new_session=True) as process:
            try:
                return process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                print(f"Linux D-Bus test timed out after {args.timeout:g} seconds", flush=True)
                return 124
            finally:
                # 测试直接退出或超时时，私有 session bus 的子进程仍可能活着。
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())

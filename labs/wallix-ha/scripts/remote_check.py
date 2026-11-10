#!/usr/bin/env python3
"""TCP checks run on the probe. Stdlib only."""

import socket
import sys


def connect(host, port, timeout):
    return socket.create_connection((host, port), timeout)


def cmd_open(host, port):
    try:
        sock = connect(host, port, 3)
    except OSError:
        print("closed")
        return 1
    sock.close()
    print("open")
    return 0


def read_line(sock):
    sock.settimeout(3)
    data = b""
    while b"\n" not in data and len(data) < 128:
        chunk = sock.recv(128)
        if not chunk:
            break
        data += chunk
    return data.decode("utf-8", "replace").strip()


def cmd_banner(host, port):
    try:
        sock = connect(host, port, 3)
    except OSError:
        print("closed")
        return 1
    try:
        print(read_line(sock))
    except OSError:
        print("closed")
        return 1
    finally:
        sock.close()
    return 0


def cmd_many(host, port, count, expect):
    seen = []
    for _ in range(count):
        sock = connect(host, port, 3)
        try:
            line = read_line(sock)
        finally:
            sock.close()
        if not line.startswith(expect):
            print(f"mismatch {line!r} expected {expect!r}")
            return 1
        seen.append(line.split()[0])
    print(f"ok {count} {seen[0]}")
    return 0


def cmd_hold(host, port):
    sock = connect(host, port, 5)
    line = read_line(sock)
    print(line, flush=True)
    sock.settimeout(90)
    try:
        rest = sock.recv(64)
        print(f"AFTER {rest!r}", flush=True)
    except OSError as exc:
        print(f"AFTER {type(exc).__name__}", flush=True)
    return 0


def main():
    command = sys.argv[1]
    if command == "open":
        return cmd_open(sys.argv[2], int(sys.argv[3]))
    if command == "banner":
        return cmd_banner(sys.argv[2], int(sys.argv[3]))
    if command == "many":
        return cmd_many(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    if command == "hold":
        return cmd_hold(sys.argv[2], int(sys.argv[3]))
    print(f"unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

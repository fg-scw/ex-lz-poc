#!/usr/bin/env python3
"""Announce the node name on the bastion ports and keep each socket open.

A Scaleway LB health check only needs the handshake. A held client blocks in
recv until this process, or the VM, closes the socket. That is the session drop.
"""

import socket
import threading

PORTS = (22, 443, 3389)


def serve(name, port, sock):
    while True:
        client, _ = sock.accept()
        try:
            client.sendall(f"{name} {port}\n".encode())
            while client.recv(4096):
                pass
        except OSError:
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass


def main():
    name = open("/etc/banner-name", encoding="utf-8").read().strip()
    listeners = []
    for port in PORTS:
        sock = socket.socket()
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", port))
        sock.listen(64)
        listeners.append((port, sock))
    for port, sock in listeners:
        threading.Thread(target=serve, args=(name, port, sock), daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()

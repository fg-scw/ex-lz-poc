#!/usr/bin/env python3
"""Behavior of a Scaleway TCP load balancer in front of two bastions.

`first` sends each new connection to the first healthy server that still has a
free slot. Round-robin, the product default, alternates. Health checks are TCP
connects, counted per frontend port. After max_retries failures the server is
marked down on that port and its sessions on that port are closed.
"""

import socket
import threading
import time


PORTS = (22, 443, 3389)


class Node:
    def __init__(self, name):
        self.name = name
        self.listening = set(PORTS)
        self.maxconn = None


class LoadBalancer:
    def __init__(self, nodes, algorithm, max_retries=2):
        self.nodes = nodes
        self.algorithm = algorithm
        self.max_retries = max_retries
        self.failures = {(node.name, port): 0 for node in nodes for port in PORTS}
        self.up = {(node.name, port): True for node in nodes for port in PORTS}
        self.sessions = {}
        self._next = 1
        self._rr = {port: 0 for port in PORTS}

    def health_check(self, port):
        for node in self.nodes:
            key = (node.name, port)
            if port in node.listening:
                self.failures[key] = 0
                self.up[key] = True
                continue
            self.failures[key] += 1
            if self.failures[key] >= self.max_retries and self.up[key]:
                self.up[key] = False
                self._drop(node.name, port)

    def _drop(self, name, port):
        self.sessions = {
            sid: session
            for sid, session in self.sessions.items()
            if not (session["node"] == name and session["port"] == port)
        }

    def _open(self, name, port):
        return sum(
            1
            for session in self.sessions.values()
            if session["node"] == name and session["port"] == port
        )

    def connect(self, port, target=None):
        chosen = None
        if self.algorithm == "roundrobin":
            candidates = [
                node
                for node in self.nodes
                if self.up[(node.name, port)]
                and port in node.listening
                and (node.maxconn is None or self._open(node.name, port) < node.maxconn)
            ]
            if not candidates:
                raise ConnectionError(port)
            chosen = candidates[self._rr[port] % len(candidates)]
            self._rr[port] += 1
        elif self.algorithm == "first":
            for node in self.nodes:
                if not (self.up[(node.name, port)] and port in node.listening):
                    continue
                if node.maxconn is not None and self._open(node.name, port) >= node.maxconn:
                    continue
                chosen = node
                break
            if chosen is None:
                raise ConnectionError(port)
        else:
            raise ValueError(self.algorithm)
        sid = self._next
        self._next += 1
        self.sessions[sid] = {"node": chosen.name, "port": port, "target": target}
        return sid

    def node_of(self, sid):
        return self.sessions[sid]["node"]


def check(name, condition):
    if not condition:
        raise SystemExit(f"échec {name}")
    print(f"ok {name}")


def fresh(algorithm):
    return LoadBalancer([Node("a"), Node("b")], algorithm)


def test_model():
    split = fresh("roundrobin")
    owners = [split.node_of(split.connect(3389)) for _ in range(10)]
    check(
        "both_listen_roundrobin_splits",
        owners.count("a") == 5 and owners.count("b") == 5,
    )

    pinned = fresh("first")
    check(
        "both_listen_first_pins_to_master",
        all(pinned.node_of(pinned.connect(port)) == "a" for port in PORTS for _ in range(10)),
    )

    primary = pinned.nodes[0]
    held = pinned.connect(3389)
    primary.listening.remove(3389)
    check("session_survives_one_failed_check", held in pinned.sessions)
    pinned.health_check(3389)
    check("session_survives_one_failed_check", held in pinned.sessions)
    pinned.health_check(3389)
    check(
        "failover_drops_held_session",
        held not in pinned.sessions and pinned.node_of(pinned.connect(3389)) == "b",
    )
    check(
        "other_ports_stay_on_master",
        pinned.node_of(pinned.connect(22)) == "a" and pinned.node_of(pinned.connect(443)) == "a",
    )

    primary.listening.add(3389)
    pinned.health_check(3389)
    check("failback_returns_to_master", pinned.node_of(pinned.connect(3389)) == "a")
    print("note failback_is_automatic")

    capped = fresh("first")
    capped.nodes[0].maxconn = 1
    first_sid = capped.connect(3389)
    second_sid = capped.connect(3389)
    check(
        "maxconn_spills_while_primary_healthy",
        capped.node_of(first_sid) == "a" and capped.node_of(second_sid) == "b",
    )

    mux = fresh("first")
    targets = []
    for target in ("t1", "t2", "t3"):
        for _ in range(2):
            sid = mux.connect(3389, target=target)
            targets.append(mux.sessions[sid])
    check(
        "one_rdp_frontend_many_targets",
        len(targets) == 6
        and {item["node"] for item in targets} == {"a"}
        and {item["target"] for item in targets} == {"t1", "t2", "t3"},
    )


class Banner:
    def __init__(self, name):
        self.name = name
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(32)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.stop = threading.Event()
        self.clients = []
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop.is_set():
            try:
                client, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.clients.append(client)
            try:
                client.sendall(f"{self.name}\n".encode())
            except OSError:
                pass

    def stop_listen(self):
        """Close the accept socket. Established clients stay up."""
        self.stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)

    def close_clients(self):
        for client in list(self.clients):
            try:
                client.close()
            except OSError:
                pass

    def close(self):
        self.stop_listen()
        self.close_clients()


class Proxy:
    def __init__(self, banners):
        self.banners = banners
        self.order = ["a", "b"]
        self.up = {name: True for name in self.order}
        self.failures = {name: 0 for name in self.order}
        self.max_retries = 2
        self.sessions = []
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(32)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop.is_set():
            try:
                client, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _pick(self):
        for name in self.order:
            if self.up[name]:
                return name
        return None

    def _handle(self, client):
        client.settimeout(2)
        name = self._pick()
        if name is None:
            client.close()
            return
        try:
            upstream = socket.create_connection(("127.0.0.1", self.banners[name].port), 2)
            banner = upstream.recv(16)
            client.sendall(banner)
        except OSError:
            client.close()
            return
        self.sessions.append((name, client, upstream))

    def health_tick(self):
        for name in self.order:
            try:
                probe = socket.create_connection(("127.0.0.1", self.banners[name].port), 0.5)
                probe.close()
                ok = True
            except OSError:
                ok = False
            if ok:
                self.failures[name] = 0
                self.up[name] = True
            else:
                self.failures[name] += 1
                if self.failures[name] >= self.max_retries and self.up[name]:
                    self.up[name] = False
                    self._drop(name)

    def _drop(self, name):
        kept = []
        for session in self.sessions:
            if session[0] != name:
                kept.append(session)
                continue
            for sock in session[1:]:
                try:
                    sock.close()
                except OSError:
                    pass
        self.sessions = kept

    def close(self):
        self.stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)


def wait_ready(port, payload):
    last = b""
    for _ in range(25):
        try:
            probe = socket.create_connection(("127.0.0.1", port), 0.5)
            probe.settimeout(0.5)
            last = probe.recv(16)
            probe.close()
            if last == payload:
                return
        except OSError:
            pass
        time.sleep(0.02)
    raise SystemExit(f"rien n'écoute sur {port}: {last!r}")


def test_sockets():
    banners = {"a": Banner("a"), "b": Banner("b")}
    proxy = Proxy(banners)
    try:
        wait_ready(banners["a"].port, b"a\n")
        wait_ready(banners["b"].port, b"b\n")
        client = socket.create_connection(("127.0.0.1", proxy.port), 2)
        client.settimeout(2)
        check("socket_pins_to_master", client.recv(16) == b"a\n")

        banners["a"].stop_listen()
        proxy.health_tick()
        client.settimeout(0.4)
        still_open = False
        try:
            client.recv(16)
        except (TimeoutError, socket.timeout):
            still_open = True
        check("socket_session_survives_one_failed_check", still_open)

        proxy.health_tick()
        try:
            after = client.recv(16)
        except OSError as exc:
            after = type(exc).__name__.encode()
        check("socket_failover_drops_held_session", after == b"")

        moved = socket.create_connection(("127.0.0.1", proxy.port), 2)
        moved.settimeout(2)
        check("socket_failover_goes_to_slave", moved.recv(16) == b"b\n")
        moved.close()

        banners["a"].close_clients()
        banners["a"] = Banner("a")
        proxy.banners = banners
        wait_ready(banners["a"].port, b"a\n")
        proxy.health_tick()
        back = socket.create_connection(("127.0.0.1", proxy.port), 2)
        back.settimeout(2)
        check("socket_failback_goes_to_master", back.recv(16) == b"a\n")
        back.close()
        client.close()
    finally:
        proxy.close()
        for banner in banners.values():
            banner.close()


def main():
    test_model()
    test_sockets()
    print("ok lb_active_passive")


if __name__ == "__main__":
    main()

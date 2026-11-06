#!/usr/bin/env python3
"""The link probe (devices investigation, 2026-11-06): a development-protocol
client that times one small request (`class.definition` of Object) against
one or more serving targets at once, in phases that separate a link that
dozes between bursts from a device that is slow:

  gaps    three requests back to back, then an idle gap of 0.25, 0.5, 1,
          2, 4 or 8 s (in turn), until the phase's time is up
  steady  one request every 20 ms
  gaps    again

Every target runs the same schedule on its own thread, so the targets share
the window. One line per request to <out>: target, phase, id, the idle time
before it (since the previous reply), the wall clock at the send, the round
trip in ms. The request ids are the target's records' ids (the shell's
requests-<tag>.txt), so the target's own service time of the same request
can be set beside the round trip.

  link-probe.py <out> <gaps seconds> <steady seconds> name=tcp://host:port=<targets file> ...

The token is read from the targets file's third field and never printed.
"""
import json
import socket
import sys
import threading
import time

GAPS = [0.25, 0.5, 1, 2, 4, 8]


def run(name, host, port, token, gaps_s, steady_s, out, lock):
    rows = []
    try:
        s = socket.create_connection((host, port), timeout=10)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        f = s.makefile("rb")
        next_id = [1]

        def request(kind, args, timeout=10):
            i = next_id[0]
            next_id[0] += 1
            line = json.dumps({"v": 1, "id": i, "kind": kind, "args": args}, separators=(",", ":")) + "\n"
            t0 = time.monotonic()
            wall = time.time()
            s.sendall(line.encode())
            s.settimeout(timeout)
            while True:
                raw = f.readline()
                if not raw:
                    raise ConnectionError("closed")
                try:
                    m = json.loads(raw)
                except ValueError:
                    continue
                if m.get("kind") == "reply" and m.get("id") == i:
                    return i, wall, (time.monotonic() - t0) * 1000, m.get("ok")

        request("session.open", {"token": token, "client": "agent:probe"})
        last = time.monotonic()

        def one(phase):
            nonlocal last
            idle = (time.monotonic() - last) * 1000
            i, wall, rtt, ok = request("class.definition", {"className": "Object"})
            last = time.monotonic()
            rows.append((name, phase, i, idle, wall, rtt, ok))

        for phase, secs in (("gaps1", gaps_s), ("steady", steady_s), ("gaps2", gaps_s)):
            end = time.monotonic() + secs
            g = 0
            while time.monotonic() < end:
                if phase == "steady":
                    t = time.monotonic()
                    one(phase)
                    time.sleep(max(0, 0.02 - (time.monotonic() - t)))
                else:
                    for _ in range(3):
                        one(phase)
                    time.sleep(GAPS[g % len(GAPS)])
                    g += 1
        s.close()
    except Exception as e:  # noqa: BLE001 - a probe reports and goes on
        rows.append((name, "error", -1, 0, time.time(), 0, str(e).replace(" ", "_")))
    with lock:
        with open(out, "a") as o:
            for r in rows:
                o.write("%s\t%s\t%d\t%.1f\t%.3f\t%.3f\t%s\n" % r)


def main():
    out, gaps_s, steady_s = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    lock = threading.Lock()
    threads = []
    for spec in sys.argv[4:]:
        name, rest = spec.split("=", 1)
        addr, targets = rest.rsplit("=", 1)
        hostport = addr[len("tcp://"):]
        host, port = hostport.rsplit(":", 1)
        with open(targets) as t:
            token = t.readline().rstrip("\n").split("\t")[2]
        th = threading.Thread(target=run, args=(name, host.strip("[]"), int(port), token, gaps_s, steady_s, out, lock))
        th.start()
        threads.append(th)
    for th in threads:
        th.join(timeout=gaps_s * 2 + steady_s + 120)


if __name__ == "__main__":
    main()

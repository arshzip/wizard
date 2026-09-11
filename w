#!/usr/bin/env python3
"""Tiny, fast WiZ LAN controller.

Usage: w c | k | n | o
       w --find
"""
import ipaddress
import json
import os
import socket
import sys
import tempfile
import time

PORT = 38899
BROADCAST = "255.255.255.255"
CONFIG = os.path.join(os.path.expanduser("~"), ".wizctl.json")
DEFAULT_IP = "192.168.29.194"


def load_config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"ip": DEFAULT_IP, "mac": "cc4085624856"}


def save_config(data):
    folder = os.path.dirname(CONFIG) or "."
    fd, path = tempfile.mkstemp(prefix=".wizctl-", dir=folder)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, separators=(",", ":"))
            f.write("\n")
        os.replace(path, CONFIG)
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.29.1", 9))
        return s.getsockname()[0]
    except OSError:
        return "192.168.29.82"
    finally:
        s.close()


def valid_reply(data):
    try:
        obj = json.loads(data.decode())
        result = obj.get("result")
        return obj if isinstance(result, dict) else None
    except (ValueError, UnicodeDecodeError):
        return None


def request(ip, payload, timeout=0.28, attempts=2):
    raw = json.dumps(payload, separators=(",", ":")).encode()
    for _ in range(attempts):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(timeout)
        try:
            s.sendto(raw, (ip, PORT))
            while True:
                data, source = s.recvfrom(4096)
                if source[0] == ip:
                    reply = valid_reply(data)
                    if reply:
                        return reply
        except (OSError, socket.timeout):
            pass
        finally:
            s.close()
    return None


def discover():
    """Fast broadcast first, then one non-blocking /24 sweep."""
    me = local_ip()
    query = json.dumps({"id": 90, "method": "getPilot", "params": {}}, separators=(",", ":")).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.10)
    found = {}
    try:
        s.bind((me, 0))
        s.sendto(query, (BROADCAST, PORT))
        end = time.monotonic() + 0.55
        while time.monotonic() < end:
            try:
                data, source = s.recvfrom(4096)
            except socket.timeout:
                continue
            reply = valid_reply(data)
            if reply and source[0] != me:  # ignore local emulators listening on the WiZ port
                found[source[0]] = reply
    except OSError:
        pass
    finally:
        s.close()
    if found:
        return found

    # Broadcast can be swallowed by mesh/AP-isolation, so probe the /24 once.
    try:
        hosts = ipaddress.ip_network(me + "/24", strict=False).hosts()
    except ValueError:
        return {}
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.08)
    try:
        s.bind((me, 0))
        for host in hosts:
            if str(host) != me:
                try:
                    s.sendto(query, (str(host), PORT))
                except OSError:
                    pass
        end = time.monotonic() + 0.65
        while time.monotonic() < end:
            try:
                data, source = s.recvfrom(4096)
            except socket.timeout:
                continue
            reply = valid_reply(data)
            if reply and source[0] != me:  # ignore local emulators listening on the WiZ port
                found[source[0]] = reply
    except OSError:
        pass
    finally:
        s.close()
    return found


def target(cfg):
    ip = cfg.get("ip")
    if ip and ip != local_ip():  # a cache pointing at this machine is poison, never trust it
        reply = request(ip, {"id": 91, "method": "getPilot", "params": {}})
        if reply:
            return ip, reply
    devices = discover()
    if not devices:
        return None, None
    mac = cfg.get("mac")
    ip, reply = next((d for d in devices.items() if d[1].get("result", {}).get("mac") == mac),
                     next(iter(devices.items())))
    cfg["ip"] = ip
    result = reply.get("result", {})
    if result.get("mac"):
        cfg["mac"] = result["mac"]
    save_config(cfg)
    return ip, reply


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print("usage: w c|k|n|o   (cool, kinda-warm, nightlight, off)")
        print("       w --find")
        return 0
    cfg = load_config()
    if args[0] in ("--find", "find"):
        devices = discover()
        if not devices:
            print("no WiZ bulbs found", file=sys.stderr)
            return 1
        for ip, reply in devices.items():
            result = reply.get("result", {})
            print(ip, result.get("mac", ""), "on" if result.get("state") else "off")
        ip, reply = next(iter(devices.items()))
        cfg.update({"ip": ip, "mac": reply.get("result", {}).get("mac", cfg.get("mac", ""))})
        save_config(cfg)
        return 0

    mode = args[0].lower()[0]
    params = {
        "c": {"state": True, "temp": 6500, "dimming": 100},
        "k": {"state": True, "temp": 3500, "dimming": 70},
        "n": {"state": True, "sceneId": 14, "dimming": 100},
        "o": {"state": False},
    }.get(mode)
    if params is None:
        print("use c, k, n, or o", file=sys.stderr)
        return 2

    ip, _ = target(cfg)
    if not ip:
        print("no WiZ bulb responding", file=sys.stderr)
        return 1
    reply = request(ip, {"id": 92, "method": "setPilot", "params": params})
    if not reply:
        # One rediscovery/retry handles stale DHCP leases and transient Wi-Fi loss.
        cfg.pop("ip", None)
        ip, _ = target(cfg)
        if ip:
            reply = request(ip, {"id": 93, "method": "setPilot", "params": params})
    if not reply:
        print("bulb did not respond", file=sys.stderr)
        return 1
    print({"c": "cool", "k": "kinda-warm", "n": "nightlight", "o": "off"}[mode])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

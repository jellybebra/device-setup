"""Generate private benchmark configs from an existing VLESS and WG export.

Write only to a private directory outside the checkout. Never prints keys.
"""
import argparse
import copy
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def prepare(args):
    output = args.output.resolve()
    checkout = Path(__file__).resolve().parent.parent
    if output == checkout or checkout in output.parents:
        raise ValueError("Private configurations must be stored outside the checkout")
    runtime = read(args.vless_runtime)
    selected = next((o for o in runtime["outbounds"]
                     if o.get("tag") == "proxy" and o.get("protocol") == "vless"), None)
    if selected is None:
        raise ValueError("Input must contain an active VLESS outbound named proxy")
    keys = read(args.wireguard_peers)
    configs = {}
    for name, port, warp_port in (("vless-direct", 19482, None),
                                  ("vless-warp-l4", 19487, 19486)):
        outbound = copy.deepcopy(selected)
        outbound["settings"]["vnext"][0]["address"] = keys["endpoint"]
        outbound.setdefault("streamSettings", {}).setdefault("sockopt", {}).pop("dialerProxy", None)
        outbound.pop("proxySettings", None)
        outbounds = [outbound]
        if warp_port:
            outbound["streamSettings"]["sockopt"]["dialerProxy"] = "warp-hop"
            outbounds.append({"tag": "warp-hop", "protocol": "socks", "settings": {
                "servers": [{"address": "127.0.0.1", "port": warp_port}]}})
        configs[name + ".json"] = {
            "log": {"loglevel": "warning"},
            "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks",
                          "settings": {"auth": "noauth", "udp": True}}],
            "outbounds": outbounds,
        }
    for mode, port in (("warp", 19506), ("direct", 19507)):
        peer = {"address": keys["endpoint"] if mode == "direct" else "127.0.0.1",
                "port": keys["port"] if mode == "direct" else 19505,
                "public_key": keys["server_public_key"], "allowed_ips": ["0.0.0.0/0"],
                "persistent_keepalive_interval": 20}
        endpoint = {"type": "wireguard", "tag": "wg", "system": False,
                    "mtu": 1200, "workers": 2, "address": [keys["clients"][mode]["address"]],
                    "private_key": keys["clients"][mode]["private_key"], "peers": [peer]}
        if mode == "direct":
            endpoint["bind_interface"] = args.interface
        configs[f"wireguard-{mode}.json"] = {
            "log": {"level": "info"},
            "dns": {"servers": [{"type": "udp", "tag": "remote", "server": "1.1.1.1",
                                 "detour": "wg"}], "strategy": "ipv4_only"},
            "inbounds": [{"type": "mixed", "tag": "in", "listen": "127.0.0.1",
                          "listen_port": port}],
            "endpoints": [endpoint],
            "route": {"rules": [{"action": "resolve", "strategy": "ipv4_only"}],
                      "final": "wg", "default_domain_resolver": "remote"},
        }
    if args.usque_account:
        account = read(args.usque_account)
        account["endpoint_v4"] = account["endpoint_h2_v4"] = "127.0.0.1"
        configs["usque-udp-local.json"] = account
    output.mkdir(parents=True, exist_ok=True)
    # Refuse overwrites of a running installation or a previous experiment.
    for name in configs:
        if (output / name).exists():
            raise FileExistsError(output / name)
    for name, config in configs.items():
        with (output / name).open("x", encoding="utf-8") as file:
            json.dump(config, file, indent=2)
        print(name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vless-runtime", type=Path, required=True)
    parser.add_argument("--wireguard-peers", type=Path, required=True)
    parser.add_argument("--usque-account", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--interface", default="Ethernet")
    prepare(parser.parse_args())

# Fixed-provider VPN failover without Reality Finder

`router_chain.py` retains the existing HTTPS + SOCKS UDP health checks, ordered
selection, recovery delay, loopback client port and fail-closed behavior. It accepts
one to three uniquely named providers; production migration keeps the first two
and removes the discovery relay. `chain_support.py` avoids importing the discovery
controller. No Finder daemon, catalogue, subscription publisher or discovery
workers are needed.

Runtime layout:

- `/opt/vpn-chain/`: these two Python files plus the shared modules below.
- `/etc/vpn-chain/chain.json`: root-owned mode-0600 private configuration, supplied
  locally. Preserve the existing client profile, port, interface and socket mark.
- `/etc/init.d/reality-chain`: install `reality-chain.init`; the service name is
  retained to avoid breaking existing integrations.
- `/tmp/reality-chain`: existing relay state, separate from Finder's data.

Shared modules copied from `../reality-finder-archive/src/`:
`runtime.py`, `storage.py`, `finder.py`, `platform_runtime.py`, `windows_runtime.py`,
`core_assets.py`, `app_paths.py`, and `router_subscription.py`. Here `finder.py`
provides parsing/configuration helpers; it does not run discovery. This layout
preserves the existing relay implementation and process cleanup watchdog.

Migration requires a brief relay restart. First verify both retained providers,
prepare the independent runtime and private configuration, stop the old relay,
start the replacement on the same port, and verify HTTPS and UDP before removing
the Finder service and data. Do not remove PassWall, VPN DNS, production Xray or
zapret. Do not copy private configuration or databases into this repository.

Run offline policy tests with `python3 -m unittest discover -s configs/cudy-tr3000/vpn-chain -p 'test_*.py'`.

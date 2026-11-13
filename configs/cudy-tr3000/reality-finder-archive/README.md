# Reality Finder: archived OpenWrt source

Source-only snapshot of the installed headless Reality Finder and its original
three-way relay, taken before removal on 2026-11-13. This is a recovery/reference
archive, not an enabled router service or a complete desktop release.

`src/` contains the Python modules; `init/` contains the original procd scripts.
`source-sha256.json` records the source hashes. No databases, discovered nodes,
subscriptions, tokens, private profiles, UCI settings, or runtime logs are included.
Xray and other third-party binaries are not bundled.

The discovery service used `/opt/reality-finder/router.py`, temporary SQLite data,
and a private Unix control socket. Restoring it requires separately supplied
private configuration and runtime dependencies; copying this folder does not
restore credentials or start the service.

The retained two-provider failover relay is documented in `../vpn-chain/`.

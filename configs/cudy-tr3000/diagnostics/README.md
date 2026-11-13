# Diagnostic snapshot retention

`disable-snapshot-copies.py` removes duplicate full-ring incident copies from the
existing Lua supervisor. The single packet ring, probe log, upload queue and
server archive remain in use. This prevents two additional rings accumulating in
OpenWrt tmpfs; it does not disable probes or packet capture.

Apply to the local supervisor source, compile with Lua `loadfile`, then restart
only the owned diagnostic processes. The script refuses unrecognized input and
is idempotent. Archive any existing `incident` / `incident-old` directories before
removing them. The previous supervisor's final-stop handler may remove temporary
credentials, so do not use that handler for an ordinary maintenance restart.

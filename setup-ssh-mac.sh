#!/usr/bin/env bash
set -euo pipefail

read -r -p "ip: " IP
read -r -p "port: " PORT
read -r -p "username: " USERNAME
read -r -p "alias: " ALIAS

SSH_DIR="$HOME/.ssh"
KEY_BASE="$SSH_DIR/id_ed25519"
PUB_KEY_FILE="${KEY_BASE}.pub"
CONFIG_FILE="$SSH_DIR/config"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY_BASE" || ! -f "$PUB_KEY_FILE" ]]; then
  ssh-keygen -t ed25519 -f "$KEY_BASE" -N ""
fi

PUB_KEY_CONTENT="$(cat "$PUB_KEY_FILE")"

ssh -p "$PORT" "$USERNAME@$IP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$PUB_KEY_CONTENT' ~/.ssh/authorized_keys || echo '$PUB_KEY_CONTENT' >> ~/.ssh/authorized_keys"

TMP_CONFIG="$(mktemp)"

if [[ -f "$CONFIG_FILE" ]]; then
  awk -v alias="$ALIAS" '
    BEGIN {skip=0}
    /^[[:space:]]*Host[[:space:]]+/ {
      if ($2 == alias) {skip=1; next}
      if (skip == 1) {skip=0}
    }
    skip == 0 {print}
  ' "$CONFIG_FILE" > "$TMP_CONFIG"
else
  : > "$TMP_CONFIG"
fi

{
  printf "\nHost %s\n" "$ALIAS"
  printf "  HostName %s\n" "$IP"
  printf "  Port %s\n" "$PORT"
  printf "  User %s\n" "$USERNAME"
  printf "  IdentityFile %s\n" "$KEY_BASE"
} >> "$TMP_CONFIG"

mv "$TMP_CONFIG" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
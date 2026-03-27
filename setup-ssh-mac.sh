#!/usr/bin/env bash

set -euo pipefail

read -rp "IP: " IP
read -rp "Port: " PORT
read -rp "Username: " USERNAME
read -rp "Alias: " ALIAS

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

mkdir -p "$SSH_DIR"
touch "$CONFIG_FILE"
chmod 700 "$SSH_DIR"
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

remove_host_block() {
  local alias="$1"
  local file="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v alias="$alias" '
    BEGIN {skip=0}
    $1=="Host" && $2==alias {skip=1; next}
    $1=="Host" && skip==1 {skip=0}
    skip==0 {print}
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

append_host_block() {
  local alias="$1"
  local ip="$2"
  local port="$3"
  local username="$4"
  local identity_file="${5:-}"

  {
    printf "\nHost %s\n" "$alias"
    printf "  HostName %s\n" "$ip"
    printf "  Port %s\n" "$port"
    printf "  User %s\n" "$username"
    if [[ -n "$identity_file" ]]; then
      printf "  IdentityFile %s\n" "$identity_file"
    fi
  } >> "$CONFIG_FILE"
}

remove_host_block "$ALIAS" "$CONFIG_FILE"
append_host_block "$ALIAS" "$IP" "$PORT" "$USERNAME"

ssh -o StrictHostKeyChecking=accept-new "$ALIAS" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'

KEY_FILE=""
if [[ -f "$SSH_DIR/id_ed25519" ]]; then
  KEY_FILE="$SSH_DIR/id_ed25519"
elif [[ -f "$SSH_DIR/id_rsa" ]]; then
  KEY_FILE="$SSH_DIR/id_rsa"
else
  KEY_FILE="$SSH_DIR/id_ed25519"
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
fi

PUB_FILE="${KEY_FILE}.pub"
PUB_KEY="$(<"$PUB_FILE")"

if command -v pbcopy >/dev/null 2>&1; then
  printf "%s" "$PUB_KEY" | pbcopy
fi

open -a TextEdit "$PUB_FILE" >/dev/null 2>&1 || true

ssh "$ALIAS" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '$PUB_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

remove_host_block "$ALIAS" "$CONFIG_FILE"
append_host_block "$ALIAS" "$IP" "$PORT" "$USERNAME" "$KEY_FILE"

echo "Done."
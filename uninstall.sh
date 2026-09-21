#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_NAME="docker-prune-pushover"
readonly BIN_PATH="/usr/local/sbin/${PROJECT_NAME}"
readonly ENV_FILE="/etc/${PROJECT_NAME}.env"
readonly SERVICE_FILE="/etc/systemd/system/${PROJECT_NAME}.service"
readonly TIMER_FILE="/etc/systemd/system/${PROJECT_NAME}.timer"
readonly LOCK_FILE="/run/lock/${PROJECT_NAME}.lock"

[[ "${EUID}" -eq 0 ]] || {
  echo "Run as root: sudo ./uninstall.sh" >&2
  exit 1
}

read -r -p "Remove ${PROJECT_NAME}, its timer, and its Pushover credentials? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || {
  echo "Cancelled."
  exit 0
}

systemctl disable --now "${PROJECT_NAME}.timer" 2>/dev/null || true

rm -f \
  "$BIN_PATH" \
  "$ENV_FILE" \
  "$SERVICE_FILE" \
  "$TIMER_FILE" \
  "$LOCK_FILE"

systemctl daemon-reload
systemctl reset-failed "${PROJECT_NAME}.service" 2>/dev/null || true

echo "Removed ${PROJECT_NAME}."

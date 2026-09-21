#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_NAME="docker-prune-pushover"
readonly INSTALL_DIR="/usr/local/lib/${PROJECT_NAME}"
readonly BIN_PATH="/usr/local/sbin/${PROJECT_NAME}"
readonly ENV_FILE="/etc/${PROJECT_NAME}.env"
readonly SERVICE_FILE="/etc/systemd/system/${PROJECT_NAME}.service"
readonly TIMER_FILE="/etc/systemd/system/${PROJECT_NAME}.timer"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  unset PUSHOVER_TOKEN PUSHOVER_USER
}
trap cleanup EXIT

die() {
  echo "Error: $*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this installer as root: sudo ./install.sh"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

validate_pushover() {
  local response http_code body

  body="$(mktemp)"
  trap 'rm -f "$body"; cleanup' EXIT

  http_code="$(
    curl --silent --show-error \
      --output "$body" \
      --write-out "%{http_code}" \
      --request POST "https://api.pushover.net/1/messages.json" \
      --form-string "token=${PUSHOVER_TOKEN}" \
      --form-string "user=${PUSHOVER_USER}" \
      --form-string "title=Docker Prune Pushover installed" \
      --form-string "message=Test notification from $(hostname -f 2>/dev/null || hostname)." \
      --form-string "priority=0"
  )" || die "Could not connect to the Pushover API."

  if [[ "$http_code" != "200" ]]; then
    echo "Pushover returned HTTP ${http_code}:" >&2
    cat "$body" >&2
    rm -f "$body"
    die "Token or user/group key validation failed."
  fi

  rm -f "$body"
  trap cleanup EXIT
}

main() {
  require_root

  for command in docker systemctl curl flock timeout install; do
    require_command "$command"
  done

  [[ -f "${SCRIPT_DIR}/${PROJECT_NAME}.sh" ]] \
    || die "Run install.sh from the cloned repository directory."
  [[ -f "${SCRIPT_DIR}/${PROJECT_NAME}.service" ]] \
    || die "Missing ${PROJECT_NAME}.service."
  [[ -f "${SCRIPT_DIR}/${PROJECT_NAME}.timer" ]] \
    || die "Missing ${PROJECT_NAME}.timer."

  systemctl is-active --quiet docker \
    || die "Docker is not active. Start it first with: sudo systemctl start docker"

  echo
  echo "Docker Prune + Pushover installer"
  echo "---------------------------------"
  echo "This installs a weekly native Docker cleanup."
  echo "It does NOT prune Docker volumes."
  echo

  read -r -s -p "Pushover application API token: " PUSHOVER_TOKEN
  echo
  [[ -n "$PUSHOVER_TOKEN" ]] || die "Pushover application API token cannot be empty."

  read -r -s -p "Pushover user or group key: " PUSHOVER_USER
  echo
  [[ -n "$PUSHOVER_USER" ]] || die "Pushover user or group key cannot be empty."

  echo
  echo "Sending a Pushover test notification..."
  validate_pushover
  echo "Pushover credentials validated."

  echo
  RETENTION_DAYS="$(prompt_default "Retention period in days for unused Docker objects" "14")"
  [[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] \
    || die "Retention must be a whole number of at least 1 day."

  SCHEDULE="$(prompt_default "Weekly schedule (systemd OnCalendar format)" "Sun *-*-* 04:30:00")"
  RANDOM_DELAY="$(prompt_default "Maximum randomized start delay" "20m")"
  TIMEOUT="$(prompt_default "Maximum cleanup runtime" "30m")"

  echo
  echo "Proposed configuration:"
  echo "  Retention:        ${RETENTION_DAYS} days"
  echo "  Schedule:         ${SCHEDULE}"
  echo "  Random delay:     ${RANDOM_DELAY}"
  echo "  Cleanup timeout:  ${TIMEOUT}"
  echo "  Volumes pruned:   no"
  echo

  read -r -p "Install and enable the weekly timer? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || {
    echo "Nothing was installed."
    exit 0
  }

  install -d -m 0755 "$INSTALL_DIR"

  install -m 0755 \
    "${SCRIPT_DIR}/${PROJECT_NAME}.sh" \
    "$BIN_PATH"

  cat >"$ENV_FILE" <<EOF
# Created by ${PROJECT_NAME} installer on $(date -Is)
PUSHOVER_TOKEN='${PUSHOVER_TOKEN}'
PUSHOVER_USER='${PUSHOVER_USER}'
RETENTION_DAYS='${RETENTION_DAYS}'
CLEANUP_TIMEOUT='${TIMEOUT}'
EOF
  chmod 0600 "$ENV_FILE"
  chown root:root "$ENV_FILE"

  sed \
    -e "s|@@BIN_PATH@@|${BIN_PATH}|g" \
    -e "s|@@ENV_FILE@@|${ENV_FILE}|g" \
    "${SCRIPT_DIR}/${PROJECT_NAME}.service" >"$SERVICE_FILE"

  sed \
    -e "s|@@ON_CALENDAR@@|${SCHEDULE}|g" \
    -e "s|@@RANDOM_DELAY@@|${RANDOM_DELAY}|g" \
    "${SCRIPT_DIR}/${PROJECT_NAME}.timer" >"$TIMER_FILE"

  chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"

  systemctl daemon-reload
  systemctl enable --now "${PROJECT_NAME}.timer"

  echo
  echo "Installed successfully."
  echo
  echo "Before the first scheduled cleanup, inspect a non-destructive report:"
  echo "  sudo ${BIN_PATH} --dry-run"
  echo
  echo "Run an actual cleanup now:"
  echo "  sudo systemctl start ${PROJECT_NAME}.service"
  echo
  echo "Inspect scheduling:"
  echo "  systemctl list-timers ${PROJECT_NAME}.timer"
  echo
  echo "Read logs:"
  echo "  journalctl -u ${PROJECT_NAME}.service -n 100 --no-pager"
}

main "$@"

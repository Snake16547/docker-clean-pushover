#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_NAME="docker-prune-pushover"
readonly ENV_FILE="/etc/${PROJECT_NAME}.env"
readonly LOCK_FILE="/run/lock/${PROJECT_NAME}.lock"

usage() {
  cat <<'EOF'
Usage:
  docker-prune-pushover [--dry-run] [--no-notify] [--help]

Options:
  --dry-run     Show Docker disk use and likely candidates; do not delete data.
  --no-notify   Do not send Pushover notifications.
  --help        Show this help text.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

DRY_RUN=0
NOTIFY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-notify)
      NOTIFY=0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ -r "$ENV_FILE" ]] || die "Missing configuration file: $ENV_FILE"

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${PUSHOVER_TOKEN:?PUSHOVER_TOKEN missing from ${ENV_FILE}}"
: "${PUSHOVER_USER:?PUSHOVER_USER missing from ${ENV_FILE}}"
: "${RETENTION_DAYS:?RETENTION_DAYS missing from ${ENV_FILE}}"
: "${CLEANUP_TIMEOUT:?CLEANUP_TIMEOUT missing from ${ENV_FILE}}"

[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] \
  || die "RETENTION_DAYS must be a positive integer."

require_command docker
require_command curl
require_command flock
require_command timeout

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
RETENTION_HOURS="$((RETENTION_DAYS * 24))"
FILTER="until=${RETENTION_HOURS}h"

notify() {
  local title="$1"
  local message="$2"
  local priority="${3:-0}"

  [[ "$NOTIFY" -eq 1 ]] || return 0

  curl --silent --show-error --fail \
    --max-time 20 \
    --request POST "https://api.pushover.net/1/messages.json" \
    --form-string "token=${PUSHOVER_TOKEN}" \
    --form-string "user=${PUSHOVER_USER}" \
    --form-string "title=${title}" \
    --form-string "message=${message}" \
    --form-string "priority=${priority}" \
    >/dev/null
}

trim_message() {
  local input="$1"
  local limit=900

  if (( ${#input} > limit )); then
    printf '%s\n…output truncated' "${input:0:limit}"
  else
    printf '%s' "$input"
  fi
}

dry_run() {
  echo "Docker cleanup dry run for: ${HOSTNAME_FQDN}"
  echo "Retention window: ${RETENTION_DAYS} days"
  echo "Volumes: never pruned"
  echo

  echo "== Docker disk usage =="
  docker system df -v || true
  echo

  echo "== Stopped containers =="
  docker ps -a \
    --filter "status=exited" \
    --filter "status=created" \
    --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' || true
  echo

  echo "== Dangling images =="
  docker image ls \
    --filter "dangling=true" \
    --format 'table {{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' || true
  echo

  echo "Note: Docker does not provide an exact non-destructive preview for"
  echo "'docker system prune'. This report is informational; the actual run"
  echo "removes only unused objects older than ${RETENTION_DAYS} days."
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  dry_run
  exit 0
fi

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  message="A cleanup was skipped because another ${PROJECT_NAME} process holds the lock."
  echo "$message"
  notify "Docker cleanup skipped: ${HOSTNAME_FQDN}" "$message" -1 || true
  exit 0
fi

if ! systemctl is-active --quiet docker; then
  message="Docker is not active; no cleanup was attempted."
  echo "$message" >&2
  notify "Docker cleanup failed: ${HOSTNAME_FQDN}" "$message" 1 || true
  exit 1
fi

started_at="$(date -Is)"
before="$(docker system df 2>&1 || true)"

set +e
output="$(
  timeout --foreground "$CLEANUP_TIMEOUT" \
    docker system prune --all --force --filter "$FILTER" 2>&1
)"
exit_code=$?
set -e

after="$(docker system df 2>&1 || true)"

if [[ "$exit_code" -eq 0 ]]; then
  message="$(
    cat <<EOF
Cleanup completed.

Retention: ${RETENTION_DAYS} days
Started: ${started_at}

Result:
$(trim_message "$output")

After cleanup:
$(trim_message "$after")
EOF
  )"

  echo "$message"
  notify "Docker cleanup complete: ${HOSTNAME_FQDN}" "$message" 0 || true
  exit 0
fi

if [[ "$exit_code" -eq 124 ]]; then
  failure_reason="Docker cleanup timed out after ${CLEANUP_TIMEOUT}."
else
  failure_reason="Docker cleanup exited with code ${exit_code}."
fi

message="$(
  cat <<EOF
${failure_reason}

Retention: ${RETENTION_DAYS} days
Started: ${started_at}

Output:
$(trim_message "$output")

Disk use before:
$(trim_message "$before")
EOF
)"

echo "$message" >&2
notify "Docker cleanup FAILED: ${HOSTNAME_FQDN}" "$message" 1 || true
exit "$exit_code"

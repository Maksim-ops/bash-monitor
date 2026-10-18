#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'Bash 4 or newer is required.\n' >&2
  exit 1
fi

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CLI_CONFIG_FILE=""
CLI_STATE_DIR=""
CLI_DRY_RUN=""

CONFIG_FILE="${SCRIPT_DIR}/monitor.conf"
STATE_DIR=""
LOCK_FILE=""
LOG_FILE="${LOG_FILE:-}"
EVENTS_LOG_FILE="${EVENTS_LOG_FILE:-}"
DRY_RUN=0

HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host')}"
ALERT_PREFIX="${ALERT_PREFIX:-[lifeorient-monitor]}"
EXPECTED_HTTP_STATUS="${EXPECTED_HTTP_STATUS:-200}"
HTTP_FAILURE_THRESHOLD="${HTTP_FAILURE_THRESHOLD:-3}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-10}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-90}"
CPU_USAGE_THRESHOLD="${CPU_USAGE_THRESHOLD:-90}"
MEMORY_USAGE_THRESHOLD="${MEMORY_USAGE_THRESHOLD:-90}"
RESOURCE_FAILURE_THRESHOLD="${RESOURCE_FAILURE_THRESHOLD:-3}"
CPU_SAMPLE_SECONDS="${CPU_SAMPLE_SECONDS:-1}"
TELEGRAM_TIMEOUT="${TELEGRAM_TIMEOUT:-15}"
# Seconds to wait before each retry of a failed Telegram send; the number of
# retries is the number of values ("10 20" = up to 3 tries in total).
TELEGRAM_RETRY_DELAYS="${TELEGRAM_RETRY_DELAYS:-10 20}"
# file-error checks: an alert stays "active" (further new lines are only counted,
# not sent) until no new matching lines have appeared for this many seconds.
FILE_ERROR_QUIET_SECONDS="${FILE_ERROR_QUIET_SECONDS:-600}"
# at most this many new bytes of a watched file are read per run
FILE_ERROR_MAX_READ_BYTES="${FILE_ERROR_MAX_READ_BYTES:-5242880}"

readonly NL=$'\n'

declare -a CHECK_ORDER=()
declare -A CHECK_KIND=()
declare -A CHECK_LABEL=()
declare -A CHECK_PARAM_1=()
declare -A CHECK_PARAM_2=()
declare -A CHECK_PARAM_3=()
declare -A CHECK_PARAM_4=()
declare -A CHECK_PARAM_5=()
declare -A CHECK_DEPENDS=()
declare -A CONTAINER_INFO=()
CONTAINER_CACHE_LOADED=0
DRY_STATE_DIR=""

timestamp() {
  date '+%Y-%m-%d %H:%M:%S %z'
}

log() {
  local line
  printf -v line '[%s] %s\n' "$(timestamp)" "$*"
  printf '%s' "$line" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s' "$line" >> "$LOG_FILE"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./monitor.sh [--config /path/to/monitor.conf] [--state-dir /path/to/state] [--dry-run]

Options:
  --config     Path to the Bash config file with registered checks.
  --state-dir  Directory for per-check state files.
  --dry-run    Print notifications to stdout instead of sending them to Telegram.
  --help       Show this help.

Config helpers:
  add_container_check <id> <container_name> [label]
  add_container_health_check <id> <container_name> [label] [failure_threshold]
  add_containers <container_name>...      (id = name with '-' -> '_', label "Docker: <name>")
  depends_on <check_id> <parent_check_id>...
  add_http_check <id> <url> [label] [expected_code] [failure_threshold] [timeout_seconds]
  add_command_check <id> <command> [label] [match_regex] [failure_threshold]
  add_disk_check <id> <path> [label] [usage_percent_threshold]
  add_resource_check <id> [label] [cpu_threshold] [memory_threshold] [failure_threshold]
  add_log_check <id> <file_path> [label] [include_regex] [exclude_regex]
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a value"
        CLI_CONFIG_FILE="$2"
        shift 2
        ;;
      --state-dir)
        [[ $# -ge 2 ]] || die "--state-dir requires a value"
        CLI_STATE_DIR="$2"
        shift 2
        ;;
      --dry-run)
        CLI_DRY_RUN="1"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

register_check() {
  local id="$1"
  local kind="$2"
  local label="$3"

  [[ "$id" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid check id '$id'. Use only letters, digits, dot, underscore, and dash."
  [[ -z "${CHECK_KIND[$id]+x}" ]] || die "Duplicate check id '$id'."

  CHECK_ORDER+=("$id")
  CHECK_KIND["$id"]="$kind"
  CHECK_LABEL["$id"]="$label"
  CHECK_PARAM_1["$id"]="${4:-}"
  CHECK_PARAM_2["$id"]="${5:-}"
  CHECK_PARAM_3["$id"]="${6:-}"
  CHECK_PARAM_4["$id"]="${7:-}"
  CHECK_PARAM_5["$id"]="${8:-}"
}

add_container_check() {
  local id="${1:?container check id is required}"
  local container_name="${2:?container name is required}"
  local label="${3:-Docker: ${container_name}}"
  register_check "$id" "container" "$label" "$container_name" "" "1"
}

# Like add_container_check, but the container must also report Docker health
# "healthy" (it needs a HEALTHCHECK); failure_threshold applies to every failure.
add_container_health_check() {
  local id="${1:?container health check id is required}"
  local container_name="${2:?container name is required}"
  local label="${3:-Docker health ${container_name}}"
  local failure_threshold="${4:-1}"
  register_check "$id" "container" "$label" "$container_name" "health" "$failure_threshold"
}

# Shorthand for plain container checks: id is the name with '-' replaced by '_'.
add_containers() {
  local name
  for name in "$@"; do
    add_container_check "${name//-/_}" "$name"
  done
}

# <check_id> is not run (so it cannot alert) while any of the listed parent
# checks is failing (alert active or at least one failed run): when a more
# general thing is down, the checks that depend on it stay quiet and do not
# waste time on timeouts. A parent must be registered (run) before its
# dependents. When the parent recovers the dependent runs again and, if it is
# still failing, alerts after its own threshold.
depends_on() {
  local check_id="${1:?check id is required}"
  local parent
  shift
  (($# > 0)) || die "depends_on '$check_id' needs at least one parent check id."
  for parent in "$@"; do
    CHECK_DEPENDS["$check_id"]+="${CHECK_DEPENDS[$check_id]:+ }${parent}"
  done
}

add_http_check() {
  local id="${1:?http check id is required}"
  local url="${2:?http url is required}"
  local label="${3:-HTTP ${url}}"
  local expected_code="${4:-$EXPECTED_HTTP_STATUS}"
  local failure_threshold="${5:-$HTTP_FAILURE_THRESHOLD}"
  local timeout_seconds="${6:-$HTTP_TIMEOUT}"
  register_check "$id" "http" "$label" "$url" "$expected_code" "$failure_threshold" "$timeout_seconds"
}

add_command_check() {
  local id="${1:?command check id is required}"
  local command_string="${2:?command is required}"
  local label="${3:-Command ${id}}"
  local match_regex="${4:-}"
  local failure_threshold="${5:-1}"
  register_check "$id" "command" "$label" "$command_string" "$match_regex" "$failure_threshold"
}

add_disk_check() {
  local id="${1:?disk check id is required}"
  local disk_path="${2:?path is required}"
  local label="${3:-Disk ${disk_path}}"
  local usage_threshold="${4:-$DISK_USAGE_THRESHOLD}"
  register_check "$id" "disk" "$label" "$disk_path" "$usage_threshold"
}

add_resource_check() {
  local id="${1:?resource check id is required}"
  local label="${2:-Host resources}"
  local cpu_threshold="${3:-$CPU_USAGE_THRESHOLD}"
  local memory_threshold="${4:-$MEMORY_USAGE_THRESHOLD}"
  local failure_threshold="${5:-$RESOURCE_FAILURE_THRESHOLD}"
  register_check "$id" "resource" "$label" "$cpu_threshold" "$memory_threshold" "$failure_threshold"
}

# Watches any plain log file on the host (one event/line per entry works best,
# e.g. JSON-lines). The first run that finds new matching lines sends an ALERT;
# while that alert is active further lines are only counted, and after
# FILE_ERROR_QUIET_SECONDS without new matches a RESOLVED summary is sent.
#   add_log_check <id> <file_path> [label] [include_regex] [exclude_regex]
# include_regex: only lines matching this are considered (empty = all new lines).
# exclude_regex: lines matching this are dropped even if include_regex matched
#   (this is how you filter out specific error types you don't want pinged for).
add_log_check() {
  local id="${1:?log check id is required}"
  local file_path="${2:?file path is required}"
  local label="${3:-File errors ${file_path}}"
  local include_regex="${4:-}"
  local exclude_regex="${5:-}"
  register_check "$id" "log" "$label" "$file_path" "$include_regex" "$exclude_regex"
}

# Journal of every ALERT / RESOLVED the monitor decided to send, with the
# full text of what it saw. One event per line so it can be grepped; written
# whether or not the Telegram delivery succeeded (status=sent|failed), so the
# file is the source of truth if a message never reached the chat.
# No-op when EVENTS_LOG_FILE is empty (it defaults to "<LOG_FILE minus .log>-events.log").
record_event() {
  local severity="$1"
  local check_id="$2"
  local label="$3"
  local status="$4"
  local details="$5"
  local attempts="${6:-1}"
  local line

  [[ -n "${EVENTS_LOG_FILE:-}" && "$DRY_RUN" != "1" ]] || return 0

  details="${details//${NL}${NL}/ | }"
  details="${details//${NL}/ | }"

  printf -v line '[%s] %s check=%s label="%s" host=%s status=%s attempts=%s details=%s\n' \
    "$(timestamp)" "$severity" "$check_id" "$label" "$HOSTNAME_LABEL" "$status" "$attempts" "$details"
  printf '%s' "$line" >> "$EVENTS_LOG_FILE" 2>/dev/null || true
}

truncate_text() {
  local text="$1"
  local limit="${2:-3200}"

  if ((${#text} > limit)); then
    printf '%s\n...\n(truncated)' "${text:0:limit}"
  else
    printf '%s' "$text"
  fi
}

build_message() {
  local severity="$1"
  local check_id="$2"
  local label="$3"
  local details="$4"
  local icon

  case "$severity" in
    ALERT) icon='❗' ;;
    RESOLVED) icon='✅' ;;
    *) icon='' ;;
  esac

  printf '%s %s %s\nHost: %s\nCheck: %s (%s)\nTime: %s\n\n%s\n' \
    "$icon" \
    "$ALERT_PREFIX" \
    "$severity" \
    "$HOSTNAME_LABEL" \
    "$label" \
    "$check_id" \
    "$(timestamp)" \
    "$(truncate_text "$details" 3200)"
}

send_notification() {
  local severity="$1"
  local check_id="$2"
  local label="$3"
  local details="$4"
  local message

  message="$(build_message "$severity" "$check_id" "$label" "$details")"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN ${severity} notification for '${check_id}'."
    printf '%s\n\n' "$message"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log "curl is not installed, cannot send Telegram notification for '$check_id'."
    record_event "$severity" "$check_id" "$label" "failed" "$details"
    return 1
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    log "Telegram settings are empty, cannot send notification for '$check_id'."
    record_event "$severity" "$check_id" "$label" "failed" "$details"
    return 1
  fi

  local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  local -a curl_args=(
    -fsS
    --max-time "$TELEGRAM_TIMEOUT"
    -X POST
    "$url"
    -d "chat_id=${TELEGRAM_CHAT_ID}"
    --data-urlencode "text=${message}"
  )

  if [[ -n "${TELEGRAM_MESSAGE_THREAD_ID:-}" ]]; then
    curl_args+=(-d "message_thread_id=${TELEGRAM_MESSAGE_THREAD_ID}")
  fi

  if [[ -n "${TELEGRAM_PARSE_MODE:-}" ]]; then
    curl_args+=(-d "parse_mode=${TELEGRAM_PARSE_MODE}")
  fi

  if [[ "${TELEGRAM_DISABLE_NOTIFICATION:-0}" == "1" ]]; then
    curl_args+=(-d "disable_notification=true")
  fi

  # A transient Telegram/network hiccup should not lose the alert: retry a few
  # times before giving up. This matters most for file-error checks, which move
  # their cursor past the lines regardless of delivery (the events journal is
  # then the only place the alert survives).
  local -a retry_delays=()
  IFS=' ' read -r -a retry_delays <<< "$TELEGRAM_RETRY_DELAYS"
  local attempt=1
  local max_attempts=$(( ${#retry_delays[@]} + 1 ))
  local retry_delay
  until curl "${curl_args[@]}" >/dev/null; do
    if (( attempt >= max_attempts )); then
      log "Telegram send failed for '$check_id' after ${attempt} attempt(s)."
      record_event "$severity" "$check_id" "$label" "failed" "$details" "$attempt"
      return 1
    fi

    retry_delay="${retry_delays[$((attempt - 1))]}"
    log "Telegram send attempt ${attempt}/${max_attempts} failed for '$check_id', retrying in ${retry_delay}s."
    sleep "$retry_delay"
    attempt=$((attempt + 1))
  done

  log "${severity} notification sent for '${check_id}'."
  record_event "$severity" "$check_id" "$label" "sent" "$details" "$attempt"
  return 0
}

state_file_for() {
  local check_id="$1"
  printf '%s/%s.state\n' "$STATE_DIR" "$check_id"
}

load_state() {
  local state_file

  STATE_ACTIVE=0
  STATE_FAIL_COUNT=0
  STATE_LAST_DETAIL=""
  STATE_LAST_CURSOR=0
  STATE_LAST_SEEN=0
  STATE_SUPPRESSED=0
  STATE_SUPPRESSED_COUNT=0
  STATE_SUPPRESSED_SAMPLE=""

  state_file="$(state_file_for "$1")"
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    STATE_ACTIVE="${ACTIVE:-0}"
    STATE_FAIL_COUNT="${FAIL_COUNT:-0}"
    STATE_LAST_DETAIL="${LAST_DETAIL:-}"
    STATE_LAST_CURSOR="${LAST_CURSOR:-0}"
    STATE_LAST_SEEN="${LAST_SEEN:-0}"
    STATE_SUPPRESSED="${SUPPRESSED:-0}"
    STATE_SUPPRESSED_COUNT="${SUPPRESSED_COUNT:-0}"
    STATE_SUPPRESSED_SAMPLE="${SUPPRESSED_SAMPLE:-}"
  fi
}

save_state() {
  local state_file
  local tmp_file

  state_file="$(state_file_for "$1")"
  tmp_file="${state_file}.tmp"

  {
    printf 'ACTIVE=%q\n' "$STATE_ACTIVE"
    printf 'FAIL_COUNT=%q\n' "$STATE_FAIL_COUNT"
    printf 'LAST_DETAIL=%q\n' "$STATE_LAST_DETAIL"
    printf 'LAST_CURSOR=%q\n' "$STATE_LAST_CURSOR"
    printf 'LAST_SEEN=%q\n' "$STATE_LAST_SEEN"
    printf 'SUPPRESSED=%q\n' "$STATE_SUPPRESSED"
    printf 'SUPPRESSED_COUNT=%q\n' "$STATE_SUPPRESSED_COUNT"
    printf 'SUPPRESSED_SAMPLE=%q\n' "$STATE_SUPPRESSED_SAMPLE"
  } > "$tmp_file"

  mv "$tmp_file" "$state_file"
}

# Prints the id of the first failing parent of a check (nothing if it has no
# dependencies or none of them is failing). "Failing" = alert active or at least
# one failed run in a row, so dependents stay quiet even before the parent's own
# threshold is reached.
failing_dependency() {
  local check_id="$1"
  local -a parents=()
  local parent state_file active fail_count
  local -a state_files

  [[ -n "${CHECK_DEPENDS[$check_id]:-}" ]] || return 0
  IFS=' ' read -r -a parents <<< "${CHECK_DEPENDS[$check_id]}"

  for parent in "${parents[@]}"; do
    if [[ "${CHECK_KIND[$parent]:-}" == "resource" ]]; then
      state_files=("$(state_file_for "${parent}.cpu")" "$(state_file_for "${parent}.memory")")
    else
      state_files=("$(state_file_for "$parent")")
    fi

    for state_file in "${state_files[@]}"; do
      [[ -f "$state_file" ]] || continue
      IFS=' ' read -r active fail_count < <(source "$state_file" >/dev/null 2>&1; printf '%s %s' "${ACTIVE:-0}" "${FAIL_COUNT:-0}")
      if [[ "$active" == "1" ]] || (( ${fail_count:-0} > 0 )); then
        printf '%s' "$parent"
        return 0
      fi
    done
  done
}

mark_failure_loaded() {
  local check_id="$1"
  local label="$2"
  local failure_threshold="$3"
  local details="$4"

  STATE_FAIL_COUNT=$((STATE_FAIL_COUNT + 1))
  STATE_LAST_DETAIL="$details"
  STATE_LAST_SEEN="$(date +%s)"

  if (( STATE_FAIL_COUNT >= failure_threshold )) && [[ "$STATE_ACTIVE" != "1" ]]; then
    if send_notification "ALERT" "$check_id" "$label" "$details"; then
      STATE_ACTIVE=1
    fi
  fi

  save_state "$check_id"
}

mark_success_loaded() {
  local check_id="$1"
  local label="$2"
  local details="$3"

  STATE_FAIL_COUNT=0
  STATE_LAST_DETAIL=""
  STATE_LAST_SEEN="$(date +%s)"

  if [[ "$STATE_ACTIVE" == "1" ]]; then
    if send_notification "RESOLVED" "$check_id" "$label" "$details"; then
      STATE_ACTIVE=0
    fi
  fi

  save_state "$check_id"
}

# One `docker inspect` for every container per run instead of one per check.
load_container_cache() {
  local name container_status health_status ids

  ((CONTAINER_CACHE_LOADED == 0)) || return 0
  CONTAINER_CACHE_LOADED=1

  command -v docker >/dev/null 2>&1 || return 0
  ids="$(docker ps -aq 2>/dev/null || true)"
  [[ -n "$ids" ]] || return 0

  while IFS='|' read -r name container_status health_status; do
    [[ -n "$name" ]] || continue
    CONTAINER_INFO["${name#/}"]="${container_status}|${health_status}"
  done < <(docker inspect -f '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' $ids 2>/dev/null || true)
}

run_container_check() {
  local check_id="$1"
  local container_name="${CHECK_PARAM_1[$check_id]}"
  local mode="${CHECK_PARAM_2[$check_id]}"
  local failure_threshold="${CHECK_PARAM_3[$check_id]:-1}"
  local label="${CHECK_LABEL[$check_id]}"
  local info container_status health_status

  load_state "$check_id"

  if ! command -v docker >/dev/null 2>&1; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "docker command is not available."
    return
  fi

  load_container_cache
  info="${CONTAINER_INFO[$container_name]:-}"

  if [[ -z "$info" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' is missing or docker inspect failed."
    return
  fi

  container_status="${info%%|*}"
  health_status="${info#*|}"

  if [[ "$container_status" != "running" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' is in '$container_status' state."
    return
  fi

  if [[ "$mode" != "health" ]]; then
    mark_success_loaded "$check_id" "$label" "Container '$container_name' is running again."
    return
  fi

  case "$health_status" in
    healthy)
      mark_success_loaded "$check_id" "$label" "Container '$container_name' health status is healthy again."
      ;;
    no-healthcheck)
      mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' has no Docker healthcheck configured."
      ;;
    *)
      mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' health status is '$health_status'."
      ;;
  esac
}

run_http_check() {
  local check_id="$1"
  local url="${CHECK_PARAM_1[$check_id]}"
  local expected_code="${CHECK_PARAM_2[$check_id]}"
  local failure_threshold="${CHECK_PARAM_3[$check_id]}"
  local timeout_seconds="${CHECK_PARAM_4[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local stderr_file
  local curl_exit_code=0
  local curl_error=""
  local response_code=""

  load_state "$check_id"

  if ! command -v curl >/dev/null 2>&1; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "curl is not installed, HTTP checks cannot run."
    return
  fi

  stderr_file="$(mktemp)"
  response_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$timeout_seconds" "$url" 2>"$stderr_file")" || curl_exit_code=$?
  curl_error="$(<"$stderr_file")"
  rm -f "$stderr_file"

  if (( curl_exit_code != 0 )); then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "HTTP request to '$url' failed with curl exit code ${curl_exit_code}. ${curl_error}"
    return
  fi

  if [[ "$response_code" != "$expected_code" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "HTTP request to '$url' returned status ${response_code}, expected ${expected_code}."
    return
  fi

  mark_success_loaded "$check_id" "$label" "HTTP endpoint '$url' returned ${response_code} again."
}

run_command_check() {
  local check_id="$1"
  local command_string="${CHECK_PARAM_1[$check_id]}"
  local match_regex="${CHECK_PARAM_2[$check_id]}"
  local failure_threshold="${CHECK_PARAM_3[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local output=""
  local exit_code=0
  local non_empty_output=""
  local matched_lines=""

  load_state "$check_id"

  output="$(bash -lc "$command_string" 2>&1)" || exit_code=$?

  if (( exit_code != 0 )); then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Command failed with exit code ${exit_code}: ${command_string}${NL}${NL}$(truncate_text "$output" 2500)"
    return
  fi

  non_empty_output="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d')"

  if [[ -n "$match_regex" ]]; then
    matched_lines="$(printf '%s\n' "$output" | grep -Ei -m 5 "$match_regex" || true)"
    if [[ -n "$matched_lines" ]]; then
      mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Command matched '${match_regex}'.${NL}${NL}$(truncate_text "$matched_lines" 2500)"
      return
    fi

    mark_success_loaded "$check_id" "$label" "Command output no longer matches '${match_regex}'."
    return
  fi

  if [[ -n "$non_empty_output" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Command returned non-empty output.${NL}${NL}$(truncate_text "$non_empty_output" 2500)"
    return
  fi

  mark_success_loaded "$check_id" "$label" "Command output is empty again."
}

run_disk_check() {
  local check_id="$1"
  local disk_path="${CHECK_PARAM_1[$check_id]}"
  local usage_threshold="${CHECK_PARAM_2[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local usage=""

  load_state "$check_id"

  usage="$(df -P "$disk_path" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}' || true)"

  if [[ -z "$usage" ]]; then
    mark_failure_loaded "$check_id" "$label" 1 "Unable to read disk usage for '$disk_path'."
    return
  fi

  if (( usage >= usage_threshold )); then
    mark_failure_loaded "$check_id" "$label" 1 "Disk usage for '$disk_path' is ${usage}%, threshold is ${usage_threshold}%."
    return
  fi

  mark_success_loaded "$check_id" "$label" "Disk usage for '$disk_path' is back to normal at ${usage}%."
}

measure_cpu_usage() {
  local _cpu user nice system idle iowait irq softirq steal guest guest_nice
  local total_1 idle_1 total_2 idle_2 delta_total delta_idle

  read -r _cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total_1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle_1=$((idle + iowait))

  sleep "$CPU_SAMPLE_SECONDS"

  read -r _cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total_2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle_2=$((idle + iowait))

  delta_total=$((total_2 - total_1))
  delta_idle=$((idle_2 - idle_1))

  if (( delta_total <= 0 )); then
    printf '0'
    return
  fi

  printf '%d' $(( (100 * (delta_total - delta_idle)) / delta_total ))
}

measure_memory_usage() {
  local mem_total mem_available mem_free buffers cached

  mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  mem_available="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

  if [[ -z "$mem_available" ]]; then
    mem_free="$(awk '/MemFree/ {print $2}' /proc/meminfo)"
    buffers="$(awk '/Buffers/ {print $2}' /proc/meminfo)"
    cached="$(awk '/^Cached/ {print $2}' /proc/meminfo)"
    mem_available=$((mem_free + buffers + cached))
  fi

  printf '%d' $(( (100 * (mem_total - mem_available)) / mem_total ))
}

run_metric_threshold_check() {
  local check_id="$1"
  local label="$2"
  local current_value="$3"
  local threshold="$4"
  local failure_threshold="$5"
  local metric_name="$6"

  load_state "$check_id"

  if (( current_value >= threshold )); then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "${metric_name} is ${current_value}%, threshold is ${threshold}%."
    return
  fi

  mark_success_loaded "$check_id" "$label" "${metric_name} is back to normal at ${current_value}%."
}

run_resource_check() {
  local check_id="$1"
  local label="${CHECK_LABEL[$check_id]}"
  local cpu_threshold="${CHECK_PARAM_1[$check_id]}"
  local memory_threshold="${CHECK_PARAM_2[$check_id]}"
  local failure_threshold="${CHECK_PARAM_3[$check_id]}"
  local cpu_usage memory_usage

  cpu_usage="$(measure_cpu_usage)"
  memory_usage="$(measure_memory_usage)"

  run_metric_threshold_check "${check_id}.cpu" "${label} CPU" "$cpu_usage" "$cpu_threshold" "$failure_threshold" "CPU usage"
  run_metric_threshold_check "${check_id}.memory" "${label} memory" "$memory_usage" "$memory_threshold" "$failure_threshold" "Memory usage"
}

run_log_check() {
  local check_id="$1"
  local file_path="${CHECK_PARAM_1[$check_id]}"
  local include_regex="${CHECK_PARAM_2[$check_id]}"
  local exclude_regex="${CHECK_PARAM_3[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local is_first_run=0 file_size cursor chunk chunk_size consumed partial_len new_content="" matched_lines="" match_count=0
  local skipped_to_tail=0 now sample

  # Checked before load_state (which would otherwise create/initialize the
  # state transparently) so we can tell "never run before" apart from "ran
  # before, cursor just happens to be 0".
  if [[ ! -f "$(state_file_for "$check_id")" ]]; then
    is_first_run=1
  fi

  load_state "$check_id"

  if [[ ! -r "$file_path" ]]; then
    log "File '$file_path' is not readable for check '$check_id', skipping this run."
    return
  fi

  # Byte size, not line count: on GNU coreutils `wc -c` on a regular file is
  # an O(1) metadata read (no need to scan the file), and reading "new since
  # last time" via `tail -c +N` seeks straight to that byte offset instead of
  # scanning from the start to find "line N". Both matter once the file is
  # large and this runs every minute from cron.
  file_size="$(wc -c < "$file_path" 2>/dev/null || printf '0')"
  file_size="${file_size//[[:space:]]/}"
  [[ "$file_size" =~ ^[0-9]+$ ]] || file_size=0

  if (( is_first_run )); then
    log "First run of log check '$check_id': starting from the current end of '$file_path' (${file_size} bytes) without reporting anything already in it."
    STATE_LAST_CURSOR="$file_size"
    save_state "$check_id"
    return
  fi

  cursor="$STATE_LAST_CURSOR"
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0

  if (( file_size < cursor )); then
    log "File '$file_path' is smaller than the saved cursor for check '$check_id' (rotated/truncated?), resetting cursor to 0."
    cursor=0
  fi

  # Never pull more than FILE_ERROR_MAX_READ_BYTES into memory: after a huge
  # burst, jump to the tail of the file and drop the first (partial) line.
  if (( file_size - cursor > FILE_ERROR_MAX_READ_BYTES )); then
    log "Check '$check_id': $((file_size - cursor)) new bytes in '$file_path', reading only the last ${FILE_ERROR_MAX_READ_BYTES}."
    cursor=$((file_size - FILE_ERROR_MAX_READ_BYTES))
    skipped_to_tail=1
  fi

  if (( file_size > cursor )); then
    chunk="$(mktemp)"
    tail -c "+$((cursor + 1))" "$file_path" 2>/dev/null | head -c "$FILE_ERROR_MAX_READ_BYTES" > "$chunk" || true
    chunk_size="$(wc -c < "$chunk")"
    chunk_size="${chunk_size//[[:space:]]/}"
    consumed="$chunk_size"

    # Only consume complete lines: a line the app is still writing is picked up
    # whole on the next run instead of being split between two runs.
    if (( chunk_size > 0 )) && [[ -n "$(tail -c 1 "$chunk")" ]]; then
      partial_len="$(tail -n 1 "$chunk" | wc -c)"
      partial_len="${partial_len//[[:space:]]/}"
      if (( partial_len < chunk_size || chunk_size >= FILE_ERROR_MAX_READ_BYTES )); then
        (( partial_len < chunk_size )) && consumed=$((chunk_size - partial_len))
        head -c "$consumed" "$chunk" > "${chunk}.c" && mv "${chunk}.c" "$chunk"
      else
        consumed=0
        : > "$chunk"
      fi
    fi

    new_content="$(<"$chunk")"
    rm -f "$chunk"
    (( skipped_to_tail )) && new_content="$(printf '%s\n' "$new_content" | sed 1d)"
    cursor=$((cursor + consumed))
  fi

  # Cursor always advances past everything we just read, whether or not it
  # matched the filters below — otherwise excluded/filtered lines would be
  # re-read (and re-considered) on every future run.
  STATE_LAST_CURSOR="$cursor"

  matched_lines="$new_content"

  if [[ -n "$include_regex" && -n "$matched_lines" ]]; then
    matched_lines="$(printf '%s\n' "$matched_lines" | grep -E "$include_regex" || true)"
  fi

  if [[ -n "$exclude_regex" && -n "$matched_lines" ]]; then
    matched_lines="$(printf '%s\n' "$matched_lines" | grep -Ev "$exclude_regex" || true)"
  fi

  now="$(date +%s)"

  if [[ -z "$matched_lines" ]]; then
    # Quiet again: close the active alert after FILE_ERROR_QUIET_SECONDS without
    # new matching lines and report how much was held back meanwhile.
    if [[ "$STATE_ACTIVE" == "1" ]] && (( now - STATE_LAST_SEEN >= FILE_ERROR_QUIET_SECONDS )); then
      if send_notification "RESOLVED" "$check_id" "$label" "No new matching lines in '${file_path}' for ${FILE_ERROR_QUIET_SECONDS}s. Lines not sent while the alert was active: ${STATE_SUPPRESSED_COUNT}.${NL}${NL}Last suppressed line:${NL}${STATE_SUPPRESSED_SAMPLE:-<none>}"; then
        STATE_ACTIVE=0
        STATE_SUPPRESSED_COUNT=0
        STATE_SUPPRESSED_SAMPLE=""
      fi
    fi
    save_state "$check_id"
    return
  fi

  match_count="$(printf '%s\n' "$matched_lines" | grep -c '.' || true)"
  STATE_LAST_SEEN="$now"

  if [[ "$STATE_ACTIVE" == "1" ]]; then
    # Alert storm protection: an alert for this check is already out and not
    # resolved yet, so new lines are only counted (the file itself keeps them).
    sample="$(printf '%s\n' "$matched_lines" | tail -n 1)"
    STATE_SUPPRESSED_COUNT=$((STATE_SUPPRESSED_COUNT + match_count))
    STATE_SUPPRESSED_SAMPLE="$(truncate_text "$sample" 600)"
    log "Check '${check_id}': ${match_count} new matching line(s) not sent, alert is already active."
    record_event "SUPPRESSED" "$check_id" "$label" "alert-active" "${match_count} new matching line(s). Last: ${sample}"
    save_state "$check_id"
    return
  fi

  if send_notification "ALERT" "$check_id" "$label" "Found ${match_count} new matching line(s) in '${file_path}'.${NL}${NL}$(truncate_text "$matched_lines" 3000)"; then
    STATE_ACTIVE=1
    STATE_SUPPRESSED_COUNT=0
    STATE_SUPPRESSED_SAMPLE=""
  fi
  save_state "$check_id"
}

dispatch_check() {
  local check_id="$1"
  local kind="${CHECK_KIND[$check_id]}"

  case "$kind" in
    container)
      run_container_check "$check_id"
      ;;
    http)
      run_http_check "$check_id"
      ;;
    command)
      run_command_check "$check_id"
      ;;
    disk)
      run_disk_check "$check_id"
      ;;
    resource)
      run_resource_check "$check_id"
      ;;
    log)
      run_log_check "$check_id"
      ;;
    *)
      die "Unknown check kind '$kind' for '$check_id'."
      ;;
  esac
}

validate_dependencies() {
  local check_id parent
  local -a parents=()
  local -A position=()
  local index=0

  for check_id in "${CHECK_ORDER[@]}"; do
    position["$check_id"]=$index
    index=$((index + 1))
  done

  for check_id in "${!CHECK_DEPENDS[@]}"; do
    [[ -n "${position[$check_id]+x}" ]] || die "depends_on: unknown check '$check_id'."
    IFS=' ' read -r -a parents <<< "${CHECK_DEPENDS[$check_id]}"
    for parent in "${parents[@]}"; do
      [[ -n "${position[$parent]+x}" ]] || die "depends_on: check '$check_id' depends on unknown check '$parent'."
      [[ "$parent" != "$check_id" ]] || die "depends_on: check '$check_id' cannot depend on itself."
      (( position[$parent] < position[$check_id] )) \
        || die "depends_on: parent '$parent' must be registered before '$check_id' in the config (checks run in registration order)."
    done
  done
}

# A check whose parent (depends_on) is failing is not run at all: it would fail
# for the same reason (and HTTP checks would just wait for their timeouts). Its
# state is left untouched, so it starts counting again once the parent is back.
# SUPPRESSED=1 in its state marks "currently skipped" so that the skip is logged
# (and journaled) once per outage, not every minute.
skip_dependent_check() {
  local check_id="$1"
  local blocker="$2"

  load_state "$check_id"
  if [[ "$STATE_SUPPRESSED" != "1" ]]; then
    STATE_SUPPRESSED=1
    log "Check '${check_id}' skipped: dependency '${blocker}' is failing."
    record_event "SKIPPED" "$check_id" "${CHECK_LABEL[$check_id]}" "dependency:${blocker}" "Not run while '${blocker}' is failing."
    save_state "$check_id"
  fi
}

resume_dependent_check() {
  local check_id="$1"

  load_state "$check_id"
  if [[ "$STATE_SUPPRESSED" == "1" ]]; then
    STATE_SUPPRESSED=0
    log "Check '${check_id}' resumed: its dependencies are healthy again."
    save_state "$check_id"
  fi
}

run_all_checks() {
  local check_id blocker

  for check_id in "${CHECK_ORDER[@]}"; do
    if [[ -n "${CHECK_DEPENDS[$check_id]:-}" ]]; then
      blocker="$(failing_dependency "$check_id")"
      if [[ -n "$blocker" ]]; then
        skip_dependent_check "$check_id" "$blocker"
        continue
      fi
      resume_dependent_check "$check_id"
    fi

    if ! dispatch_check "$check_id"; then
      log "Check '$check_id' crashed unexpectedly."
    fi
  done
}

acquire_lock() {
  LOCK_FILE="${LOCK_FILE:-$STATE_DIR/monitor.lock}"

  if ! command -v flock >/dev/null 2>&1; then
    return
  fi

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Another monitor.sh process is already running. Exiting."
    exit 0
  fi
}

load_config() {
  CONFIG_FILE="${CLI_CONFIG_FILE:-$CONFIG_FILE}"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "${SCRIPT_DIR}/monitor.conf.example" ]]; then
      die "Config file '$CONFIG_FILE' does not exist. Copy '${SCRIPT_DIR}/monitor.conf.example' to '${SCRIPT_DIR}/monitor.conf' and adjust it."
    fi
    die "Config file '$CONFIG_FILE' does not exist."
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

finalize_runtime_settings() {
  STATE_DIR="${CLI_STATE_DIR:-${STATE_DIR:-${SCRIPT_DIR}/.monitor-state}}"
  DRY_RUN="${CLI_DRY_RUN:-${DRY_RUN:-0}}"
  mkdir -p "$STATE_DIR"

  # A dry run behaves like a real one (alerts are "sent", cursors move), so it
  # must never touch the real state: work on a throw-away copy.
  if [[ "$DRY_RUN" == "1" ]]; then
    DRY_STATE_DIR="$(mktemp -d)"
    cp -a "$STATE_DIR/." "$DRY_STATE_DIR/" 2>/dev/null || true
    trap 'rm -rf "$DRY_STATE_DIR"' EXIT
    STATE_DIR="$DRY_STATE_DIR"
  fi

  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" || die "Cannot create log directory for '$LOG_FILE'."
    touch "$LOG_FILE" || die "Cannot write to LOG_FILE '$LOG_FILE'."
  fi

  if [[ -z "${EVENTS_LOG_FILE:-}" && -n "${LOG_FILE:-}" ]]; then
    EVENTS_LOG_FILE="${LOG_FILE%.log}-events.log"
  fi

  if [[ -n "${EVENTS_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$EVENTS_LOG_FILE")" || die "Cannot create log directory for '$EVENTS_LOG_FILE'."
    touch "$EVENTS_LOG_FILE" || die "Cannot write to EVENTS_LOG_FILE '$EVENTS_LOG_FILE'."
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "TELEGRAM_BOT_TOKEN is not set."
    [[ -n "${TELEGRAM_CHAT_ID:-}" ]] || die "TELEGRAM_CHAT_ID is not set."
  fi

  ((${#CHECK_ORDER[@]} > 0)) || die "No checks were registered in '$CONFIG_FILE'."
  validate_dependencies
}

main() {
  parse_args "$@"
  load_config
  finalize_runtime_settings
  acquire_lock
  log "Starting monitoring run with ${#CHECK_ORDER[@]} checks."
  run_all_checks
  log "Finished monitoring run."
}

main "$@"

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
LOG_INITIAL_LOOKBACK_SECONDS="${LOG_INITIAL_LOOKBACK_SECONDS:-300}"
TELEGRAM_TIMEOUT="${TELEGRAM_TIMEOUT:-15}"

declare -a CHECK_ORDER=()
declare -A CHECK_KIND=()
declare -A CHECK_LABEL=()
declare -A CHECK_PARAM_1=()
declare -A CHECK_PARAM_2=()
declare -A CHECK_PARAM_3=()
declare -A CHECK_PARAM_4=()
declare -A CHECK_PARAM_5=()

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
  add_http_check <id> <url> [label] [expected_code] [failure_threshold] [timeout_seconds]
  add_db_check <id> <command> [label] [match_regex] [failure_threshold]
  add_command_check <id> <command> [label] [match_regex] [failure_threshold]
  add_disk_check <id> <path> [label] [usage_percent_threshold]
  add_resource_check <id> [label] [cpu_threshold] [memory_threshold] [failure_threshold]
  add_log_check <id> <container_name> <pattern> [label] [failure_threshold] [initial_lookback_seconds]
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
  local label="${3:-Container ${container_name}}"
  register_check "$id" "container" "$label" "$container_name"
}

add_container_health_check() {
  local id="${1:?container health check id is required}"
  local container_name="${2:?container name is required}"
  local label="${3:-Docker health ${container_name}}"
  local failure_threshold="${4:-1}"
  register_check "$id" "container_health" "$label" "$container_name" "$failure_threshold"
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

add_db_check() {
  add_command_check "$@"
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

add_log_check() {
  local id="${1:?log check id is required}"
  local container_name="${2:?container name is required}"
  local pattern="${3:?log pattern is required}"
  local label="${4:-Logs ${container_name}}"
  local failure_threshold="${5:-1}"
  local initial_lookback_seconds="${6:-$LOG_INITIAL_LOOKBACK_SECONDS}"
  register_check "$id" "log" "$label" "$container_name" "$pattern" "$failure_threshold" "$initial_lookback_seconds"
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
    return 1
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    log "Telegram settings are empty, cannot send notification for '$check_id'."
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

  if ! curl "${curl_args[@]}" >/dev/null; then
    log "Telegram send failed for '$check_id'."
    return 1
  fi

  log "${severity} notification sent for '${check_id}'."
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

  state_file="$(state_file_for "$1")"
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    STATE_ACTIVE="${ACTIVE:-0}"
    STATE_FAIL_COUNT="${FAIL_COUNT:-0}"
    STATE_LAST_DETAIL="${LAST_DETAIL:-}"
    STATE_LAST_CURSOR="${LAST_CURSOR:-0}"
    STATE_LAST_SEEN="${LAST_SEEN:-0}"
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
  } > "$tmp_file"

  mv "$tmp_file" "$state_file"
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

run_container_check() {
  local check_id="$1"
  local container_name="${CHECK_PARAM_1[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local status=""

  load_state "$check_id"

  if ! command -v docker >/dev/null 2>&1; then
    mark_failure_loaded "$check_id" "$label" 1 "docker command is not available."
    return
  fi

  status="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)"

  if [[ -z "$status" ]]; then
    mark_failure_loaded "$check_id" "$label" 1 "Container '$container_name' is missing or docker inspect failed."
    return
  fi

  if [[ "$status" != "running" ]]; then
    mark_failure_loaded "$check_id" "$label" 1 "Container '$container_name' is in '$status' state."
    return
  fi

  mark_success_loaded "$check_id" "$label" "Container '$container_name' is running again."
}

run_container_health_check() {
  local check_id="$1"
  local container_name="${CHECK_PARAM_1[$check_id]}"
  local failure_threshold="${CHECK_PARAM_2[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local inspect_output=""
  local container_status=""
  local health_status=""

  load_state "$check_id"

  if ! command -v docker >/dev/null 2>&1; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "docker command is not available."
    return
  fi

  inspect_output="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container_name" 2>/dev/null || true)"

  if [[ -z "$inspect_output" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' is missing or docker inspect failed."
    return
  fi

  container_status="${inspect_output%%|*}"
  health_status="${inspect_output#*|}"

  if [[ "$container_status" != "running" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' is in '$container_status' state."
    return
  fi

  if [[ "$health_status" == "healthy" ]]; then
    mark_success_loaded "$check_id" "$label" "Container '$container_name' health status is healthy again."
    return
  fi

  if [[ "$health_status" == "no-healthcheck" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' has no Docker healthcheck configured."
    return
  fi

  mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Container '$container_name' health status is '$health_status'."
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
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Command failed with exit code ${exit_code}: ${command_string}\n\n$(truncate_text "$output" 2500)"
    return
  fi

  non_empty_output="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d')"

  if [[ -n "$match_regex" ]]; then
    matched_lines="$(printf '%s\n' "$output" | grep -Ei -m 5 "$match_regex" || true)"
    if [[ -n "$matched_lines" ]]; then
      mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Command matched '${match_regex}'.\n\n$(truncate_text "$matched_lines" 2500)"
      return
    fi

    mark_success_loaded "$check_id" "$label" "Command output no longer matches '${match_regex}'."
    return
  fi

  if [[ -n "$non_empty_output" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Command returned non-empty output.\n\n$(truncate_text "$non_empty_output" 2500)"
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
  local container_name="${CHECK_PARAM_1[$check_id]}"
  local pattern="${CHECK_PARAM_2[$check_id]}"
  local failure_threshold="${CHECK_PARAM_3[$check_id]}"
  local initial_lookback_seconds="${CHECK_PARAM_4[$check_id]}"
  local label="${CHECK_LABEL[$check_id]}"
  local now since output="" exit_code=0 matched_lines=""

  load_state "$check_id"

  if ! command -v docker >/dev/null 2>&1; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "docker command is not available, log checks cannot run."
    return
  fi

  now="$(date +%s)"

  if [[ "$STATE_LAST_CURSOR" =~ ^[0-9]+$ ]] && (( STATE_LAST_CURSOR > 0 )); then
    since="$STATE_LAST_CURSOR"
  else
    since=$((now - initial_lookback_seconds))
  fi

  output="$(docker logs --since "$since" --timestamps "$container_name" 2>&1)" || exit_code=$?
  STATE_LAST_CURSOR="$now"

  if (( exit_code != 0 )); then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Unable to read logs from '$container_name' (exit code ${exit_code}).\n\n$(truncate_text "$output" 2500)"
    return
  fi

  matched_lines="$(printf '%s\n' "$output" | grep -Ei -m 5 "$pattern" || true)"

  if [[ -n "$matched_lines" ]]; then
    mark_failure_loaded "$check_id" "$label" "$failure_threshold" "Found log matches in '$container_name' for pattern '${pattern}'.\n\n$(truncate_text "$matched_lines" 2500)"
    return
  fi

  mark_success_loaded "$check_id" "$label" "No new log matches found in '$container_name' for pattern '${pattern}'."
}

dispatch_check() {
  local check_id="$1"
  local kind="${CHECK_KIND[$check_id]}"

  case "$kind" in
    container)
      run_container_check "$check_id"
      ;;
    container_health)
      run_container_health_check "$check_id"
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

run_all_checks() {
  local check_id

  for check_id in "${CHECK_ORDER[@]}"; do
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

  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" || die "Cannot create log directory for '$LOG_FILE'."
    touch "$LOG_FILE" || die "Cannot write to LOG_FILE '$LOG_FILE'."
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "TELEGRAM_BOT_TOKEN is not set."
    [[ -n "${TELEGRAM_CHAT_ID:-}" ]] || die "TELEGRAM_CHAT_ID is not set."
  fi

  ((${#CHECK_ORDER[@]} > 0)) || die "No checks were registered in '$CONFIG_FILE'."
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

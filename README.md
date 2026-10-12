# lifeorient-monitoring

Simple cron-driven monitoring in Bash for Docker containers, HTTP endpoints, MySQL checks, disk usage, host CPU and memory, and log patterns. The script keeps per-check state on disk, sends alerts to Telegram only once while the issue is active, and sends a resolved message when the problem disappears.

## Files

- `monitor.sh` - main script for cron.
- `monitor.conf.example` - config template with all check types.
- `monitor.conf.prod.example` - sanitized production-style example with real container names and URLs but placeholder secrets.
- `.monitor-state/` or your custom `STATE_DIR` - state files created at runtime.

## What the script does

- Checks Docker containers by name and alerts if a container is missing or not running.
- Optionally checks Docker `healthy` / `unhealthy` status for containers that define `HEALTHCHECK`.
- Sends HTTP requests and alerts after N consecutive bad responses.
- Runs SQL or any shell command and alerts when the command returns output, matches a regex, or exits with an error.
- Alerts on disk usage above a threshold.
- Tracks host CPU and memory, with a configurable consecutive-failure threshold.
- Scans Docker logs for a regex like `exception|fatal error`.
- Watches any plain log file on the host (not tied to Docker or any one
  service) and notifies about every run that has new matching lines —
  useful for "tell me about every new error" rather than "tell me when a
  problem starts/stops". Supports an include and an exclude regex so you
  can filter out specific error types without touching the app.
- Suppresses duplicate alerts while the same problem is still active
  (this applies to the ALERT/RESOLVED-style checks above, not to the
  file-error check, which has no "resolved" state — see below).
- Sends a resolved message when the state returns to normal.

## Setup

1. Copy `monitor.conf.example` to `monitor.conf`.
   If you want a production-oriented template, start from `monitor.conf.prod.example` instead.
2. Fill in `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, host label, and your real checks.
3. Optionally set `LOG_FILE="/var/log/lifeorient-monitor.log"` in `monitor.conf` if you want the script itself to append run logs there.
4. Make sure `bash`, `curl`, `docker`, `df`, `awk`, `sed`, `grep`, and optionally `flock` are installed on the server.
5. If you query MySQL through Docker, use `docker exec ... mysql ...` inside `add_db_check`.

## Run manually

```bash
chmod +x monitor.sh
./monitor.sh --config ./monitor.conf --dry-run
./monitor.sh --config ./monitor.conf
```

`--dry-run` prints the messages locally instead of sending them to Telegram. This is the safest way to test the config before putting it under cron.

## Cron example

```cron
* * * * * /opt/lifeorient-monitor/monitor.sh --config /opt/lifeorient-monitor/monitor.conf >> /var/log/lifeorient-monitor.log 2>&1
```

If `LOG_FILE` is set inside the config, the script also writes its own start/end and notification events to that file.

## Config examples

Container status:

```bash
add_container_check "nginx_container" "nginx" "Docker: nginx"
```

Optional Docker health status:

```bash
add_container_health_check "nginx_health" "nginx" "Docker health: nginx" 1
```

HTTP endpoint with 3 consecutive failures before alerting:

```bash
add_http_check "api_health" "http://127.0.0.1:8081/health" "HTTP: api health" 200 3 10
```

MySQL check through a Docker container:

```bash
add_db_check \
  "stuck_orders" \
  "docker exec mysql-db env MYSQL_PWD='change-me' mysql -N -B -uroot app_db -e \"SELECT id FROM orders WHERE status = 'STUCK' LIMIT 10\"" \
  "MySQL: stuck orders" \
  ""
```

Disk, resources, and logs:

```bash
add_disk_check "root_disk" "/" "Disk: /" 90
add_resource_check "host_resources" "Host resources" 90 90 3
add_log_check "php_exceptions" "php-fpm" "exception|fatal error|traceback" "Logs: php-fpm exceptions" 1 300
```

File-based error log, with filtering (not tied to Docker/a specific service — any plain file works):

```bash
add_file_error_check \
  "reports_app_errors" \
  "/root/reports/uploads/events.log" \
  "Errors: reports app" \
  "" \
  "\"context\":\"some_noisy_known_issue\""
```

- `<id>` and `<file_path>` are required; `[label]` defaults to `File errors <file_path>`.
- `[include_regex]` (4th arg): only new lines matching this are considered. Empty means every new line.
- `[exclude_regex]` (5th arg): new lines matching this are dropped even if `include_regex` matched — edit this to silence a specific error type without changing the app.
- Unlike `add_log_check`, this has no ALERT/RESOLVED pairing: it simply notifies once per run that finds new matching lines (with up to ~3000 characters of them in the message), and stays silent on runs with nothing new. Reading resumes from the line after the last one it processed; if the file is shorter than last time (rotated/truncated), it starts over from line 1.

## Notes

- `add_db_check` is just an alias for `add_command_check`, so you can reuse the same mechanism for any custom shell probe later.
- `add_container_health_check` is meant only for containers that really define Docker `HEALTHCHECK`. If the container has no healthcheck, that monitor will alert about the missing Docker health status.
- For DB checks, return empty output when everything is fine. Any non-empty output will fire the alert unless you pass a regex and only want matches to fire.
- For `mysql`, prefer `env MYSQL_PWD='secret' mysql ...` instead of `-psecret`, otherwise the client writes a warning to stderr and the check will keep firing.
- The script uses one state file per check. If Telegram delivery fails, the state stays unresolved so the script retries on the next run instead of silently losing the alert.

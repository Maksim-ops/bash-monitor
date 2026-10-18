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
- Watches any plain log file on the host (`add_log_check`, not tied to Docker or
  any one service) for new matching lines, with an include and an exclude regex
  so you can filter out specific error types without touching the app. The
  first run with new matches alerts; further lines are held back until the log
  has been quiet for a while.
- Suppresses duplicate alerts while the same problem is still active (this
  includes the log check: while its alert is active, new lines are only
  counted and listed in the journal, see below).
- Sends a resolved message when the state returns to normal.
- Dependencies between checks (`depends_on`): when a more general check is
  failing (a container, the proxy, the tunnel to the home server), checks that
  depend on it are skipped and send no alerts of their own.

## Setup

1. Copy `monitor.conf.example` to `monitor.conf`.
   If you want a production-oriented template, start from `monitor.conf.prod.example` instead.
2. Fill in `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, host label, and your real checks.
3. Optionally set `LOG_FILE="/var/log/lifeorient-monitor.log"` in `monitor.conf` if you want the script itself to append run logs there.
4. Make sure `bash`, `curl`, `docker`, `df`, `awk`, `sed`, `grep`, and optionally `flock` are installed on the server.
5. If you query MySQL through Docker, use `docker exec ... mysql ...` inside `add_command_check`.

## Run manually

```bash
chmod +x monitor.sh
./monitor.sh --config ./monitor.conf --dry-run
./monitor.sh --config ./monitor.conf
```

`--dry-run` prints the messages locally instead of sending them to Telegram. It runs against a throw-away copy of the state directory, so it never changes the real state (cursors, active alerts) and writes nothing to the alert journal: it is safe to run on the production config at any time.

## Cron example

```cron
* * * * * /opt/lifeorient-monitor/monitor.sh --config /opt/lifeorient-monitor/monitor.conf >> /var/log/lifeorient-monitor.log 2>&1
```

If `LOG_FILE` is set inside the config, the script also writes its own start/end and notification events to that file.

## Telegram retries

A failed Telegram send is retried after the pauses listed in `TELEGRAM_RETRY_DELAYS` (seconds, default `"10 20"`): the first retry is 10 s after the first failure, the second 20 s after the second one, so up to 3 tries in total. The number of values is the number of retries (empty = no retries). Each try is bounded by `TELEGRAM_TIMEOUT` (default 15), so a fully unreachable Telegram can hold one notification for roughly 75 s with the defaults. That blocks the rest of the run, and the run lock makes the next cron run exit early meanwhile (the checks catch up on the following run).

## Alert journal

Every ALERT and RESOLVED the monitor decides to send is also recorded, with the full text of what it saw, in a separate one-event-per-line file:

```
[2026-10-18 21:58:27 +0300] ALERT check=reports_app_events label="Errors: reports app" host=lifeorient status=sent attempts=1 details=Found 2 new matching line(s) ... | {"ts":...}
[2026-10-18 21:58:27 +0300] RESOLVED check=reports_db label="Docker: reports-db" host=lifeorient status=sent attempts=1 details=Container 'reports-db' is running again.
```

- `status=sent` - delivered to Telegram; `status=failed` - the monitor wanted to send it but Telegram delivery failed even after retries (so the journal is the source of truth if a message never reached the chat). `attempts=N` is how many sends it took. A failed ALERT/RESOLVED of a state check is retried on the next run and recorded again; a failed file-error alert is not (its cursor has already moved on), it survives only in the journal.
- Newlines inside `details` are replaced with ` | `.
- Path: `EVENTS_LOG_FILE` in `monitor.conf`. If it is not set but `LOG_FILE` is, it defaults to `<LOG_FILE without .log>-events.log` (e.g. `/var/log/lifeorient-monitor-events.log`). Without both, the journal is off.
- `--dry-run` does not write to the journal.
- Add the file to logrotate next to `LOG_FILE`.

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
add_command_check \
  "stuck_orders" \
  "docker exec mysql-db env MYSQL_PWD='change-me' mysql -N -B -uroot app_db -e \"SELECT id FROM orders WHERE status = 'STUCK' LIMIT 10\"" \
  "MySQL: stuck orders" \
  ""
```

Disk, resources, and logs:

```bash
add_disk_check "root_disk" "/" "Disk: /" 90
add_resource_check "host_resources" "Host resources" 90 90 3
```

Log file check with filtering (not tied to Docker or a specific service — any plain file works):

```bash
add_log_check \
  "reports_app_errors" \
  "/root/reports/uploads/events.log" \
  "Errors: reports app" \
  "" \
  "\"context\":\"some_noisy_known_issue\""
```

- `<id>` and `<file_path>` are required; `[label]` defaults to `File errors <file_path>`.
- `[include_regex]` (4th arg): only new lines matching this are considered. Empty means every new line.
- `[exclude_regex]` (5th arg): new lines matching this are dropped even if `include_regex` matched — edit this to silence a specific error type without changing the app.
- Alert storm protection: the first run that finds new matching lines sends an ALERT (with up to ~3000 characters of them). While that alert is active, further matching lines are NOT sent: they are counted (and journaled as `SUPPRESSED`; the file itself keeps them). Once there were no new matching lines for `FILE_ERROR_QUIET_SECONDS` (default 600), a RESOLVED message reports how many lines were held back and the last one, and the next error alerts again. A distinct error that arrives during an active alert is therefore only seen in the file/journal and in that summary.
- At most `FILE_ERROR_MAX_READ_BYTES` (default 5 MB) of new data are read per run (after a bigger burst only the tail is read), and only complete lines are consumed, so a line the app is still writing is never split between two runs.
- First time a given check id runs, it records the file's current size and reports nothing — existing content is never dumped into a notification, only lines appended after that first run.
- Cursor tracking is a byte offset (one small number per check in its state file), not a line count: getting the current file size and reading "everything since the saved offset" are both cheap, independent of how large the file has grown, so this is safe to run every minute from cron even against a multi-GB file. If the file is now smaller than the saved offset (rotated/truncated), it resets to the start and resumes from there.

## Dependencies between checks

```bash
depends_on "tunnel_public" "tunnel_endpoint" "tunnel_nginx"
```

While any of the listed parent checks is failing (alert active, or at least one failed run), the dependent check is **not run at all**: it would fail for the same reason, and HTTP checks would only burn time on their timeouts. The skip is logged and journaled once per outage as `SKIPPED ... dependency:<parent>`. Details:

- The dependent's state is left untouched while it is skipped, so it starts counting from scratch when the parent is back: after recovery it runs on the next run and alerts only after its own failure threshold. A dependent that never alerted sends no RESOLVED.
- A parent counts as failing as soon as it has a failed run, even before its own failure threshold is reached, so a short flake of the parent also skips its dependents for that run.
- A dependent that was already alerting stays in that state during the outage and resolves normally once it runs and passes again.
- A parent must be registered before its dependents in the config (checks run in registration order); `monitor.sh` refuses to start otherwise, and also on unknown ids.
- Dependencies can be chained (a parent may itself depend on another check).

## Notes

- `add_containers name...` registers plain container checks in one line (id = name with `-` replaced by `_`, label `Docker: <name>`); `add_container_check` and `add_container_health_check` remain for custom ids/labels or when the container must be Docker-healthy. All container checks share one `docker inspect` per run.
- `add_command_check` runs any shell probe (SQL through `docker exec`, `docker logs ... | grep`, a script): it alerts while the command prints something (or matches the optional regex) and resolves when the output is empty again.
- `add_container_health_check` is meant only for containers that really define Docker `HEALTHCHECK`. If the container has no healthcheck, that monitor will alert about the missing Docker health status.
- For DB checks, return empty output when everything is fine. Any non-empty output will fire the alert unless you pass a regex and only want matches to fire.
- For `mysql`, prefer `env MYSQL_PWD='secret' mysql ...` instead of `-psecret`, otherwise the client writes a warning to stderr and the check will keep firing.
- The script uses one state file per check. If Telegram delivery fails, the state stays unresolved so the script retries on the next run instead of silently losing the alert.

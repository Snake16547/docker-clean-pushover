# Docker Prune Pushover

A small, host-native Docker cleanup tool for Linux systems using systemd. It safely prunes unused Docker objects on a schedule and sends success, skipped-run, and failure notifications to Pushover.

It is intended for self-hosted Docker and Docker Compose servers where you want predictable cleanup without another always-running management container.

## What it does

On its scheduled run, the tool executes:

```bash
docker system prune --all --force --filter "until=<retention>"
```

By default, it retains unused objects created within the last 14 days.

It removes eligible:

- Stopped containers
- Unused images, including tagged images not used by any container
- Unused networks
- Unused build cache

It does **not** prune Docker volumes.

## Why volumes are excluded

Volumes may contain persistent data such as databases, application settings, media metadata, or uploaded files. Docker does not include volumes in `docker system prune` unless `--volumes` is specified, and this project deliberately never enables that flag.

If you want to clean volumes, audit them manually:

```bash
docker volume ls
docker volume ls -qf dangling=true
```

Do not automate volume deletion unless you fully understand every volume on the host.

## Features

- Native Docker CLI cleanup; no cleanup container required
- Systemd service and weekly timer
- Pushover success, failure, and skipped-run notifications
- Interactive installer that validates Pushover credentials
- Root-only credential file at `/etc/docker-prune-pushover.env`
- `flock` to prevent simultaneous cleanup jobs
- A configurable Docker-cleanup timeout
- A non-destructive `--dry-run` report
- Configurable retention, schedule, delay, and timeout
- Clean uninstaller

## Requirements

- Linux host using systemd
- Docker Engine with the `docker` CLI available to root
- `curl`
- `flock` and `timeout` from GNU coreutils/util-linux
- A Pushover account
- A Pushover application API token and user or group key

## Install

Clone the repository on the Docker host:

```bash
git clone https://github.com/Snake16547/docker-clean-pushover.git
cd docker-prune-pushover
sudo ./install.sh
```

The installer will:

1. Check that Docker and required commands are installed.
2. Prompt for your Pushover application API token.
3. Prompt for your Pushover user or group key.
4. Send a test Pushover notification to validate the credentials.
5. Prompt for retention, schedule, random delay, and timeout.
6. Install and enable the systemd timer.

The default configuration is:

| Setting | Default |
|---|---|
| Retention period | 14 days |
| Schedule | Sunday at 04:30 local time |
| Start jitter | Up to 20 minutes |
| Cleanup timeout | 30 minutes |
| Volume pruning | Disabled permanently |

## Inspect before cleaning

Run the dry-run report before manually triggering the first cleanup:

```bash
sudo /usr/local/sbin/docker-prune-pushover --dry-run
```

This displays Docker disk usage, stopped containers, and dangling images. Docker does not expose a perfect non-destructive preview of `docker system prune`, so the report is informational and makes no changes.

## Run now

Trigger a real cleanup immediately:

```bash
sudo systemctl start docker-prune-pushover.service
```

Follow the service logs:

```bash
journalctl -u docker-prune-pushover.service -f
```

Review the last completed run:

```bash
systemctl status docker-prune-pushover.service
journalctl -u docker-prune-pushover.service -n 100 --no-pager
```

## Timer management

Show the next scheduled run:

```bash
systemctl list-timers docker-prune-pushover.timer
```

Disable scheduled cleanup without uninstalling:

```bash
sudo systemctl disable --now docker-prune-pushover.timer
```

Re-enable it:

```bash
sudo systemctl enable --now docker-prune-pushover.timer
```

## Configuration

The installed configuration file is:

```text
/etc/docker-prune-pushover.env
```

It is owned by root and permissions are set to `0600`.

Example:

```bash
PUSHOVER_TOKEN='your-application-token'
PUSHOVER_USER='your-user-or-group-key'
RETENTION_DAYS='14'
CLEANUP_TIMEOUT='30m'
```

After changing `RETENTION_DAYS` or `CLEANUP_TIMEOUT`, no daemon reload is required; the new values apply on the next service run.

To change the schedule, edit:

```text
/etc/systemd/system/docker-prune-pushover.timer
```

Then reload systemd:

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker-prune-pushover.timer
```

For example, run every Wednesday at 03:15:

```ini
OnCalendar=Wed *-*-* 03:15:00
```

## Notification behavior

The tool sends:

- A normal-priority notification after successful cleanup.
- A quiet notification if another cleanup already holds the lock.
- A high-priority notification if Docker is inactive, the prune command fails, or cleanup exceeds the configured timeout.

Notification errors do not change the cleanup result. For example, a successful cleanup remains successful if the Pushover API is temporarily unavailable.

## Security notes

- Do not commit `/etc/docker-prune-pushover.env`.
- Do not paste Pushover tokens into GitHub issues, logs, or screenshots.
- Only root can read the installed credentials file.
- The project never handles Docker volumes automatically.
- Treat Docker daemon access as privileged access to the host.

## Uninstall

From the cloned repository:

```bash
sudo ./uninstall.sh
```

The uninstaller disables the timer and removes the script, service units, lock file, and Pushover credential file.

## Troubleshooting

Verify Docker is healthy:

```bash
sudo systemctl status docker
docker info
docker system df -v
```

Check cleanup logs:

```bash
journalctl -u docker-prune-pushover.service -n 200 --no-pager
```

Check the timer:

```bash
systemctl status docker-prune-pushover.timer
systemctl list-timers --all | grep docker-prune-pushover
```

If a cleanup times out, investigate Docker daemon and storage-driver logs:

```bash
journalctl -u docker --since "2 hours ago" --no-pager
```

Look for storage, filesystem, overlay, snapshot, or I/O errors. A cleanup task that routinely hangs is usually a Docker daemon or host-storage problem—not a reason to allow indefinitely running prune jobs.

## License

MIT.

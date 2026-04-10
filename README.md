# MikroTik SSH Backup & Git Sync

A POSIX-compliant shell script to automatically back up MikroTik (RouterOS) configurations via SSH and commit them to a Git repository.

## Features

* **Pre-flight Checks:** Verifies ICMP reachability and SSH key validity before attempting to export, preventing stalled sessions.
* **Clean Git History:** Automatically strips dynamic RouterOS timestamps (e.g., `# 2026-04-10 by RouterOS...`) from the output, ensuring commits only reflect actual configuration changes.
* **Custom Ports:** Supports non-standard SSH ports directly in the IP list (format `IP:PORT`).
* **Execution Modes:** Can run as a continuous background daemon or as a single-run task optimized for `cron`.
* **Lightweight:** Written strictly for `/bin/sh`, making it suitable for minimal environments like Alpine Linux or base Docker images.

---

## Prerequisites

* `git`
* `ssh` (OpenSSH client)
* `ping`
* An SSH key-pair configured for passwordless authentication on the target MikroTik devices.

---

## Environment Variables

The script is configured entirely via environment variables.

### Mandatory

| Variable | Description | Example |
| :--- | :--- | :--- |
| `GIT_REPO_URL` | URL of your target Git repository. | `https://github.com/user/repo.git` |
| `GIT_ACCESS_TOKEN` | Personal Access Token for Git authentication. | `ghp_xxxxxxxxxxxx` |
| `ROUTER_IPS` | Space-separated list of target IPs or IP:PORT combinations. | `192.168.88.1 10.0.0.1:8022` |

### Optional

| Variable | Default | Description |
| :--- | :--- | :--- |
| `SSH_USER` | `backup` | The SSH username for the MikroTik devices. |
| `SSH_KEY_PATH` | `$HOME/.ssh/id_rsa` | Path to the private SSH key. |
| `RUN_INTERVAL_MINUTES` | `1440` | Backup frequency in minutes (used only in daemon mode). |
| `RUN_ONCE` | `false` | Set to `true` to run the backup cycle once and exit (required for Cron). |
| `REPO_DIR` | `./backup` | Local directory where the Git repository will be cloned. |
| `EXPORT_SENSITIVE_DATA`| `false` | Set to `true` to include sensitive data like passwords and keys in the export. |

---

## Deployment Options

### Option 1: Docker Compose (Recommended for Containerized Environments)

This is the easiest way to manage the backup service. 

1. Create a `docker-compose.yml` file in the same directory as your script and `Dockerfile`:

```yaml
services:
  mikrotik-backup:
    build: .
    image: mikrotik-backup:latest
    container_name: mkt-backup
    restart: unless-stopped
    environment:
      - TZ=Europe/London
      - GIT_REPO_URL=https://github.com/my/repo.git
      - GIT_ACCESS_TOKEN=your_token_here
      - ROUTER_IPS=192.168.1.1 192.168.1.2:8022
      - RUN_INTERVAL_MINUTES=1440
    volumes:
      # Mount your private SSH key as read-only
      - ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro
      # Optional: mount a local directory to access backup files directly
      # - ./local_backup_data:/backup
```

Start the container in the background:

```Bash
docker compose up -d
```

### Option 2: Docker CLI (docker run)
If you prefer not to use Compose, you can build and run the container directly via the Docker CLI.

Build the image:

```Bash
docker build -t mikrotik-backup .
```

Run the container as a background daemon:

```Bash
docker run -d \
  --name mkt-backup \
  --restart unless-stopped \
  -e TZ="Europe/London" \
  -e GIT_REPO_URL="https://github.com/my/repo.git" \
  -e GIT_ACCESS_TOKEN="your_token_here" \
  -e ROUTER_IPS="192.168.1.1 10.0.0.1:8022" \
  -e RUN_INTERVAL_MINUTES="1440" \
  -v ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro \
  mikrotik-backup
```

### Option 3: Scheduled via Cron (Bare Metal)
If you are not using Docker, cron is the most resource-efficient way to run the script on a standard Linux server.

Open crontab: crontab -e

Add a scheduled task (e.g., daily at 02:00 AM) with RUN_ONCE="true":

```Bash
0 2 * * * GIT_REPO_URL="https://github.com/my/repo.git" GIT_ACCESS_TOKEN="token" ROUTER_IPS="192.168.1.1" RUN_ONCE="true" /path/to/mikrotik_backup.sh >> /var/log/mkt_backup.log 2>&1
```

### Option 4: Background Daemon (Bare Metal)
Useful for environments without a task scheduler where Docker is not an option. The script will handle sleeping between cycles natively.

```Bash
export GIT_REPO_URL="https://github.com/my/repo.git"
export GIT_ACCESS_TOKEN="your_token_here"
export ROUTER_IPS="192.168.1.1 10.10.10.1:2222"
export RUN_INTERVAL_MINUTES=60 

chmod +x mikrotik_backup.sh
nohup ./mikrotik_backup.sh &
```

### Option 5: Scheduled via Ofelia (Docker Job Scheduler)

If you manage your Docker environment with [Ofelia](https://github.com/mcuadros/ofelia) for centralized task scheduling, you can integrate the backup script using Docker labels. 

In this setup, we override the container's default command to keep it idle (`sleep infinity`), instruct the script to run only once (`RUN_ONCE=true`), and let Ofelia execute the script inside the container on a schedule.

1. Create or update your `docker-compose.yml`:

```yaml
services:
  mikrotik-backup:
    build: .
    image: mikrotik-backup:latest
    container_name: mkt-backup
    restart: unless-stopped
    command: sleep infinity # Keeps the container running idly
    environment:
      - RUN_ONCE=true # Instructs the script to execute one cycle and exit
      - TZ=Europe/London
      - GIT_REPO_URL=https://github.com/my/repo.git
      - GIT_ACCESS_TOKEN=your_token_here
      - ROUTER_IPS=192.168.1.1 192.168.1.2:8022
    volumes:
      - ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro
    labels:
      ofelia.enabled: "true"
      # Ofelia uses 6-field cron format (Sec Min Hour Day Month Weekday)
      ofelia.job-exec.mkt-backup.schedule: "0 0 2 * * *" # Runs daily at 02:00:00 AM
      ofelia.job-exec.mkt-backup.command: "./mikrotik_backup.sh"

  ofelia:
    image: mcuadros/ofelia:latest
    container_name: ofelia
    depends_on:
      - mikrotik-backup
    command: daemon --docker
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

Start the stack:

```Bash
docker compose up -d
```

Note: Ofelia uses the Go cron implementation, which requires 6 fields for exact times (e.g., 0 0 2 * * * for 2:00 AM) or accepts descriptors like @daily or @midnight.
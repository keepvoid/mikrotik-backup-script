#!/bin/sh

# Mandatory Variables
GIT_REPO_URL="${GIT_REPO_URL:?ERROR: GIT_REPO_URL is required (e.g., https://github.com/user/repo.git)}"
GIT_ACCESS_TOKEN="${GIT_ACCESS_TOKEN:?ERROR: GIT_ACCESS_TOKEN is required}"

# Example: ROUTER_IPS="192.168.88.1 10.0.0.1:8022 172.16.0.5"
ROUTER_IPS="${ROUTER_IPS:?ERROR: ROUTER_IPS is required (space-separated list of IPs or IP:PORT)}"

# Optional Variables with Defaults
SSH_USER="${SSH_USER:-backup}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
RUN_INTERVAL_MINUTES="${RUN_INTERVAL_MINUTES:-1440}" # Default: 24 hours (1440 mins)
RUN_ONCE="${RUN_ONCE:-false}" # Set to "true" to run once and exit
REPO_DIR="${REPO_DIR:-./backup}"
EXPORT_SENSITIVE_DATA="${EXPORT_SENSITIVE_DATA:-false}"
GIT_BRANCH="${GIT_BRANCH:-master}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Determine the export command based on sensitive data flag
if [ "$EXPORT_SENSITIVE_DATA" = "true" ] || [ "$EXPORT_SENSITIVE_DATA" = "1" ]; then
    EXPORT_CMD="/export show-sensitive"
else
    EXPORT_CMD="/export hide-sensitive"  
fi

# Inject Git Token into the URL for authentication
AUTH_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://oauth2:${GIT_ACCESS_TOKEN}@|")

# SSH options to prevent interactive prompts from blocking the script
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 -i $SSH_KEY_PATH"

while true; do
    log "Starting backup cycle."

    # 1. Ping test and filter reachable routers
    AVAILABLE_ROUTERS=""
    for TARGET in $ROUTER_IPS; do
        # Extract IP and Port from IP:PORT format
        IP="${TARGET%%:*}"
        PORT="${TARGET##*:}"
        
        # If no port was provided, string remains the same, so set default port 22
        [ "$IP" = "$PORT" ] && PORT=22

        if ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
            # Next, test SSH connection and key validity with a simple RouterOS command
            if ssh $SSH_OPTS -p "$PORT" "${SSH_USER}@${IP}" ":put true" >/dev/null 2>&1; then
                AVAILABLE_ROUTERS="$AVAILABLE_ROUTERS $TARGET"
                log "Router $IP (Port: $PORT) is REACHABLE and SSH key accepted."
            else
                log "WARNING: Router $IP is pingable, but SSH connection failed (check key, port $PORT, or firewall). Skipping."
            fi
        else
            log "Router $IP is UNREACHABLE (ping failed). Skipping."
        fi
    done

    AVAILABLE_ROUTERS=$(echo "$AVAILABLE_ROUTERS" | sed 's/^ *//')

    if [ -z "$AVAILABLE_ROUTERS" ]; then
        log "No routers are available in this cycle."
    else
        # 2. Setup / Update Git Repository
        if [ ! -d "$REPO_DIR/.git" ]; then
            log "Repository not found in $REPO_DIR. Cloning..."
            git clone "$AUTH_REPO_URL" "$REPO_DIR" || {
                log "ERROR: Failed to clone repository."
                exit 1
            }
        else
            log "Repository exists. Pulling latest changes..."
            cd "$REPO_DIR" || exit 1
            # Ensure the remote URL has the current token in case it changed
            git remote set-url origin "$AUTH_REPO_URL"
            git pull origin $GIT_BRANCH
            cd - >/dev/null || exit 1
        fi

        # 3. Backup available routers
        for TARGET in $AVAILABLE_ROUTERS; do
            IP="${TARGET%%:*}"
            PORT="${TARGET##*:}"

            [ "$IP" = "$PORT" ] && PORT=22

            log "Processing router: $IP (Port: $PORT)"
            
            # Fetch identity (hostname)
            HOSTNAME=$(ssh $SSH_OPTS -p "$PORT" "${SSH_USER}@${IP}" ":put [/system identity get name]" 2>/dev/null | tr -d '\r')
            
            if [ -z "$HOSTNAME" ]; then
                log "WARNING: Failed to retrieve identity for $IP. Using IP as fallback."
                HOSTNAME="$IP"
            fi

            # Export configuration
            log "Exporting configuration for $HOSTNAME..."
            ssh $SSH_OPTS -p "$PORT" "${SSH_USER}@${IP}" "$EXPORT_CMD" > "$REPO_DIR/${HOSTNAME}.rsc" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                sed '/^# [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/d' "$REPO_DIR/${HOSTNAME}.rsc" > "$REPO_DIR/${HOSTNAME}.rsc.tmp"
                mv "$REPO_DIR/${HOSTNAME}.rsc.tmp" "$REPO_DIR/${HOSTNAME}.rsc"
                log "Successfully backed up $HOSTNAME."
            else
                log "ERROR: Backup failed for $HOSTNAME."
                # Remove empty file if ssh failed mid-way
                [ ! -s "$REPO_DIR/${HOSTNAME}.rsc" ] && rm -f "$REPO_DIR/${HOSTNAME}.rsc"
            fi
        done

        # 4. Commit and Push if there are changes
        cd "$REPO_DIR" || exit 1
        
        if [ -n "$(git status --porcelain)" ]; then
            log "Changes detected. Committing to repository..."
            git config user.name "MikroTik AutoBackup"
            git config user.email "backup@mikrotik.local"
            
            git add .
            git commit -m "Auto backup: $(date '+%Y-%m-%d %H:%M:%S')"
            
            if git push origin HEAD; then
                log "Successfully pushed changes to repository."
            else
                log "ERROR: Failed to push changes."
            fi
        else
            log "No changes detected in configurations. Nothing to commit."
        fi
        
        cd - >/dev/null || exit 1
    fi

    # 5. Cycle Management
    if [ "$RUN_ONCE" = "true" ] || [ "$RUN_ONCE" = "1" ]; then
        log "RUN_ONCE flag is set. Exiting script."
        break
    fi

    SLEEP_SECONDS=$((RUN_INTERVAL_MINUTES * 60))
    log "Cycle complete. Sleeping for $RUN_INTERVAL_MINUTES minutes..."
    sleep $SLEEP_SECONDS
done
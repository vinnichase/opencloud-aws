#!/bin/bash
#
# OpenCloud WebDAV Mount & Sync Script
# Mounts an OpenCloud WebDAV server using rclone, with optional bidirectional sync
#
# Usage:
#   ./opencloud-mount.sh setup     - Configure rclone remote and sync folders
#   ./opencloud-mount.sh mount     - Mount the WebDAV share (manual)
#   ./opencloud-mount.sh unmount   - Unmount the share
#   ./opencloud-mount.sh sync      - Run bidirectional sync
#   ./opencloud-mount.sh resync    - Full resync [local|remote|newer]
#   ./opencloud-mount.sh status    - Check mount and sync status
#   ./opencloud-mount.sh install   - Install launchd sync service (every 60s)
#   ./opencloud-mount.sh uninstall - Remove launchd sync service
#

set -e

# Configuration
REMOTE_NAME="opencloud"
CONFIG_FILE="$HOME/.opencloud-mount.conf"
SYNC_LOCK_FILE="$HOME/.opencloud-sync.lock"
SYNC_FAIL_COUNT_FILE="$HOME/.opencloud-sync-failures"
SYNC_MAX_FAILURES=3
DEFAULT_MOUNT_POINT="$HOME/OpenCloud"
DEFAULT_CACHE_SIZE="10"
DEFAULT_SYNC_LOCAL=""
DEFAULT_SYNC_REMOTE=""

# Launchd plist paths
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
SYNC_PLIST="$LAUNCHD_DIR/com.opencloud.sync.plist"
SYNC_LABEL="com.opencloud.sync"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load config file if it exists
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}"
    CACHE_SIZE="${CACHE_SIZE:-$DEFAULT_CACHE_SIZE}"
    SYNC_LOCAL="${SYNC_LOCAL:-$DEFAULT_SYNC_LOCAL}"
    SYNC_REMOTE="${SYNC_REMOTE:-$DEFAULT_SYNC_REMOTE}"
}

# Check if rclone is installed
check_rclone() {
    if ! command -v rclone &> /dev/null; then
        log_error "rclone is not installed. Install it with:"
        echo "  brew install rclone    # macOS"
        echo "  sudo apt install rclone  # Ubuntu/Debian"
        exit 1
    fi
}

# Setup rclone remote configuration
setup_remote() {
    log_info "Setting up rclone remote '$REMOTE_NAME'..."

    # Prompt for server URL
    echo -n "Enter OpenCloud server URL (e.g., cloud.example.com): "
    read -r server_url

    # Strip protocol if provided
    server_url="${server_url#https://}"
    server_url="${server_url#http://}"
    # Strip trailing slash
    server_url="${server_url%/}"

    # Build full WebDAV URL
    local webdav_url="https://${server_url}/remote.php/webdav/"

    # Prompt for username
    echo -n "Enter username: "
    read -r username

    # Prompt for password (hidden)
    echo -n "Enter password: "
    read -rs password
    echo ""

    # Prompt for mount point
    echo -n "Enter mount point [$DEFAULT_MOUNT_POINT]: "
    read -r mount_point
    mount_point="${mount_point:-$DEFAULT_MOUNT_POINT}"

    # Prompt for cache size limit in GB
    echo -n "Enter local cache size limit in GB [$DEFAULT_CACHE_SIZE]: "
    read -r cache_size
    cache_size="${cache_size:-$DEFAULT_CACHE_SIZE}"

    # Prompt for bidirectional sync (optional)
    echo ""
    echo "Bidirectional sync keeps a local folder synced with a remote folder."
    echo "This gives native disk speed for apps like Ableton, with changes syncing every minute."
    echo "(Leave empty to skip sync setup)"
    echo ""
    echo -n "Enter local folder to sync (e.g., ~/Music/AbletonProjects): "
    read -r sync_local

    sync_remote=""
    if [ -n "$sync_local" ]; then
        # Expand tilde
        sync_local="${sync_local/#\~/$HOME}"
        echo -n "Enter remote folder to sync (e.g., Projects/Ableton): "
        read -r sync_remote
    fi

    if [ -z "$server_url" ] || [ -z "$username" ] || [ -z "$password" ]; then
        log_error "Server URL, username, and password are required"
        exit 1
    fi

    # Save config and reload
    cat > "$CONFIG_FILE" <<EOF
MOUNT_POINT="$mount_point"
CACHE_SIZE="$cache_size"
SYNC_LOCAL="$sync_local"
SYNC_REMOTE="$sync_remote"
EOF
    load_config
    log_info "Mount point: $MOUNT_POINT"
    log_info "Cache size limit: ${CACHE_SIZE}GB"
    if [ -n "$SYNC_LOCAL" ] && [ -n "$SYNC_REMOTE" ]; then
        log_info "Sync: $SYNC_LOCAL <-> $REMOTE_NAME:$SYNC_REMOTE"
    fi

    # Obscure the password for rclone
    local obscured_pass
    obscured_pass=$(rclone obscure "$password")

    # Create/update the remote
    rclone config create "$REMOTE_NAME" webdav \
        url="$webdav_url" \
        vendor="owncloud" \
        user="$username" \
        pass="$obscured_pass"

    log_info "Remote '$REMOTE_NAME' configured successfully"
    log_info "WebDAV URL: $webdav_url"
    log_info "Testing connection..."

    if rclone lsd "$REMOTE_NAME:" &>/dev/null; then
        log_info "Connection test passed"
    else
        log_error "Connection test failed"
        exit 1
    fi
}

# Check if already mounted
is_mounted() {
    mount | grep -q "rclone.*$MOUNT_POINT" 2>/dev/null || \
    mount | grep -q "$MOUNT_POINT" 2>/dev/null
}

# Mount the WebDAV share
do_mount() {
    # Check if remote exists
    if ! rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
        log_warn "Remote '$REMOTE_NAME' not configured. Running setup..."
        setup_remote
    fi

    # Create mount point if needed
    mkdir -p "$MOUNT_POINT"

    # Check if already mounted
    if is_mounted; then
        log_info "Already mounted at $MOUNT_POINT"
        return 0
    fi

    log_info "Mounting OpenCloud to $MOUNT_POINT..."

    # Mount with optimal settings for WebDAV
    rclone mount "$REMOTE_NAME:" "$MOUNT_POINT" \
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --vfs-cache-max-size "${CACHE_SIZE}G" \
        --vfs-read-chunk-size 64M \
        --vfs-read-chunk-size-limit 512M \
        --buffer-size 64M \
        --dir-cache-time 5m \
        --poll-interval 15s \
        --daemon \
        --log-file="$HOME/.opencloud-mount.log" \
        --log-level INFO

    # Wait a moment and verify
    sleep 2
    if is_mounted; then
        log_info "Successfully mounted at $MOUNT_POINT"
    else
        log_error "Mount failed. Check $HOME/.opencloud-mount.log for details"
        exit 1
    fi
}

# Unmount the share
do_unmount() {
    if ! is_mounted; then
        log_info "Not currently mounted"
        return 0
    fi

    log_info "Unmounting $MOUNT_POINT..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        umount "$MOUNT_POINT" 2>/dev/null || diskutil unmount "$MOUNT_POINT"
    else
        fusermount -u "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT"
    fi

    log_info "Unmounted successfully"
}

# Bidirectional sync
do_sync() {
    if [ -z "$SYNC_LOCAL" ] || [ -z "$SYNC_REMOTE" ]; then
        log_error "Sync not configured. Run setup to configure sync folders."
        exit 1
    fi

    # Check if remote exists
    if ! rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
        log_error "Remote '$REMOTE_NAME' not configured. Run setup first."
        exit 1
    fi

    # Create local folder if needed
    mkdir -p "$SYNC_LOCAL"

    # Check for lock file (prevent overlapping syncs)
    if [ -f "$SYNC_LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$SYNC_LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "Sync already running (PID $lock_pid), skipping"
            return 0
        else
            # Stale lock file, remove it
            rm -f "$SYNC_LOCK_FILE"
        fi
    fi

    # Create lock file
    echo $$ > "$SYNC_LOCK_FILE"
    trap 'rm -f "$SYNC_LOCK_FILE"' EXIT

    log_info "Syncing $SYNC_LOCAL <-> $REMOTE_NAME:$SYNC_REMOTE"

    # Track failure count for status display
    local fail_count=0
    if [ -f "$SYNC_FAIL_COUNT_FILE" ]; then
        fail_count=$(cat "$SYNC_FAIL_COUNT_FILE")
    fi

    # Run bisync (no auto-resync, run 'resync' command manually if needed)
    if rclone bisync "$SYNC_LOCAL" "$REMOTE_NAME:$SYNC_REMOTE" \
        --create-empty-src-dirs \
        --compare size,modtime \
        --slow-hash-sync-only \
        --resilient \
        -v \
        --log-file="$HOME/.opencloud-sync.log" 2>&1; then
        log_info "Sync completed successfully"
        rm -f "$SYNC_FAIL_COUNT_FILE"
    else
        fail_count=$((fail_count + 1))
        echo "$fail_count" > "$SYNC_FAIL_COUNT_FILE"
        log_error "Sync failed ($fail_count consecutive). Check $HOME/.opencloud-sync.log"
        log_error "To recover, run: $0 resync"
    fi

    rm -f "$SYNC_LOCK_FILE"
    trap - EXIT
}

# Manual resync with selectable mode
do_resync() {
    local mode="${1:-newer}"
    local resync_mode

    case "$mode" in
        local)
            resync_mode="path1"
            ;;
        remote)
            resync_mode="path2"
            ;;
        newer)
            resync_mode="newer"
            ;;
        *)
            log_error "Invalid mode: $mode"
            echo "Usage: $0 resync [local|remote|newer]"
            echo ""
            echo "Modes:"
            echo "  local  - Local folder is source of truth"
            echo "  remote - Remote folder is source of truth"
            echo "  newer  - Newer file wins (default, restores deleted files)"
            exit 1
            ;;
    esac

    if [ -z "$SYNC_LOCAL" ] || [ -z "$SYNC_REMOTE" ]; then
        log_error "Sync not configured. Run setup to configure sync folders."
        exit 1
    fi

    # Check if remote exists
    if ! rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
        log_error "Remote '$REMOTE_NAME' not configured. Run setup first."
        exit 1
    fi

    mkdir -p "$SYNC_LOCAL"

    log_warn "Running resync with mode: $mode ($resync_mode)"
    log_info "Local:  $SYNC_LOCAL"
    log_info "Remote: $REMOTE_NAME:$SYNC_REMOTE"

    if rclone bisync "$SYNC_LOCAL" "$REMOTE_NAME:$SYNC_REMOTE" \
        --resync \
        --resync-mode "$resync_mode" \
        --create-empty-src-dirs \
        --compare size,modtime \
        --slow-hash-sync-only \
        --resilient \
        -v \
        --log-file="$HOME/.opencloud-sync.log" 2>&1; then
        log_info "Resync completed successfully"
        rm -f "$SYNC_FAIL_COUNT_FILE"
    else
        log_error "Resync failed. Check $HOME/.opencloud-sync.log"
    fi
}

# Check if launchd job is loaded and running
is_launchd_loaded() {
    local label="$1"
    launchctl list 2>/dev/null | grep -q "$label"
}

is_launchd_running() {
    local label="$1"
    local pid
    pid=$(launchctl list 2>/dev/null | grep "$label" | awk '{print $1}')
    [ -n "$pid" ] && [ "$pid" != "-" ]
}

# Show status
show_status() {
    echo "OpenCloud Status"
    echo "================"
    echo ""

    # Remote configuration
    echo "Remote Configuration"
    echo "--------------------"
    if rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
        echo -e "Remote:    ${GREEN}configured${NC}"
        echo "WebDAV:    $(rclone config show "$REMOTE_NAME" | grep url | cut -d= -f2 | xargs)"
    else
        echo -e "Remote:    ${YELLOW}not configured${NC} (run: $0 setup)"
    fi

    echo ""
    echo "Mount"
    echo "-----"
    echo "Mount point: $MOUNT_POINT"
    echo "Cache size:  ${CACHE_SIZE}GB"
    echo "Cache path:  ~/.cache/rclone/vfs/$REMOTE_NAME/"
    if is_mounted; then
        echo -e "Status:      ${GREEN}MOUNTED${NC}"
        df -h "$MOUNT_POINT" 2>/dev/null | tail -1 | awk '{print "Disk usage:  " $3 " used / " $4 " available"}'
    else
        echo -e "Status:      ${YELLOW}NOT MOUNTED${NC}"
    fi

    echo ""
    echo "Bidirectional Sync"
    echo "------------------"
    if [ -n "$SYNC_LOCAL" ] && [ -n "$SYNC_REMOTE" ]; then
        echo "Local:       $SYNC_LOCAL"
        echo "Remote:      $REMOTE_NAME:$SYNC_REMOTE"
        if [ -f "$SYNC_LOCK_FILE" ]; then
            echo -e "Status:      ${YELLOW}SYNCING${NC}"
        elif [ -f "$SYNC_FAIL_COUNT_FILE" ]; then
            local fails
            fails=$(cat "$SYNC_FAIL_COUNT_FILE")
            echo -e "Status:      ${RED}FAILING${NC} ($fails consecutive, run: $0 resync)"
        else
            echo -e "Status:      ${GREEN}OK${NC}"
        fi

        echo ""
        echo "Launchd Service (sync)"
        echo "----------------------"
        if [ -f "$SYNC_PLIST" ]; then
            echo -e "Installed:   ${GREEN}yes${NC}"
            if is_launchd_loaded "$SYNC_LABEL"; then
                if is_launchd_running "$SYNC_LABEL"; then
                    echo -e "Status:      ${GREEN}RUNNING${NC}"
                else
                    echo -e "Status:      ${GREEN}LOADED${NC} (waiting for next interval)"
                fi
            else
                echo -e "Status:      ${YELLOW}NOT LOADED${NC} (run: $0 install)"
            fi
        else
            echo -e "Installed:   ${YELLOW}no${NC}"
        fi
    else
        echo "Sync:        Not configured"
    fi

    echo ""
    echo "Logs"
    echo "----"
    echo "Mount log:   ~/.opencloud-mount.log"
    echo "Sync log:    ~/.opencloud-sync.log"
}

# Install launchd services
install_launchd() {
    if [ -z "$SYNC_LOCAL" ] || [ -z "$SYNC_REMOTE" ]; then
        log_error "Sync not configured. Run setup first to configure sync folders."
        exit 1
    fi

    local script_path
    script_path=$(realpath "$0")

    mkdir -p "$LAUNCHD_DIR"

    # Create sync plist (runs every 60 seconds)
    log_info "Creating sync launchd service..."
    cat > "$SYNC_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SYNC_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$script_path</string>
        <string>sync</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.opencloud-sync-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.opencloud-sync-launchd.log</string>
</dict>
</plist>
EOF

    # Unload existing service if loaded
    if is_launchd_loaded "$SYNC_LABEL"; then
        launchctl unload "$SYNC_PLIST" 2>/dev/null || true
    fi

    # Load service
    log_info "Loading launchd service..."
    launchctl load "$SYNC_PLIST"

    log_info "Sync service installed and started"
    log_info "Sync will run every 60 seconds and at login"
    echo ""
    log_info "View status with: $0 status"
}

# Uninstall launchd services
uninstall_launchd() {
    local removed=false

    # Remove old mount service if it exists (legacy cleanup)
    local old_mount_plist="$LAUNCHD_DIR/com.opencloud.mount.plist"
    if [ -f "$old_mount_plist" ]; then
        log_info "Removing mount launchd service..."
        launchctl unload "$old_mount_plist" 2>/dev/null || true
        rm -f "$old_mount_plist"
        log_info "Mount service removed"
        removed=true
    fi

    # Remove sync service
    if [ -f "$SYNC_PLIST" ]; then
        log_info "Removing sync launchd service..."
        if is_launchd_loaded "$SYNC_LABEL"; then
            launchctl unload "$SYNC_PLIST" 2>/dev/null || true
        fi
        rm -f "$SYNC_PLIST"
        log_info "Sync service removed"
        removed=true
    fi

    if [ "$removed" = false ]; then
        log_info "No services installed"
    fi
}

# Main
check_rclone
load_config

case "${1:-}" in
    setup)
        setup_remote
        ;;
    mount)
        do_mount
        ;;
    unmount|umount)
        do_unmount
        ;;
    sync)
        do_sync
        ;;
    resync)
        do_resync "${2:-}"
        ;;
    status)
        show_status
        ;;
    install)
        install_launchd
        ;;
    uninstall)
        uninstall_launchd
        ;;
    *)
        echo "Usage: $0 {setup|mount|unmount|sync|resync|status|install|uninstall}"
        echo ""
        echo "Commands:"
        echo "  setup     - Configure rclone remote and sync folders"
        echo "  mount     - Mount OpenCloud WebDAV to $MOUNT_POINT"
        echo "  unmount   - Unmount the share"
        echo "  sync      - Run bidirectional sync (for fast local access)"
        echo "  resync    - Full resync [local|remote|newer] (default: newer)"
        echo "  status    - Show mount, sync, and launchd service status"
        echo "  install   - Install launchd sync service (runs every 60s)"
        echo "  uninstall - Remove launchd sync service"
        exit 1
        ;;
esac

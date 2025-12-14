#!/bin/bash
#
# OpenCloud WebDAV Mount & Sync Script
# Mounts an OpenCloud WebDAV server using rclone, with optional bidirectional sync
#
# Usage:
#   ./opencloud-mount.sh setup              - Configure rclone remote
#   ./opencloud-mount.sh mount              - Mount the WebDAV share
#   ./opencloud-mount.sh unmount            - Unmount the share
#   ./opencloud-mount.sh install <name>     - Add sync destination and install service
#   ./opencloud-mount.sh uninstall <name>   - Remove launchd service for destination
#   ./opencloud-mount.sh sync               - Run all syncs
#   ./opencloud-mount.sh sync ls            - List all sync destinations
#   ./opencloud-mount.sh sync rm <name>     - Remove destination from config
#   ./opencloud-mount.sh resync <name> [mode] - Full resync for destination
#   ./opencloud-mount.sh status             - Show status
#

set -e

# Configuration
REMOTE_NAME="opencloud"
CONFIG_FILE="$HOME/.opencloud-mount.conf"
SYNC_DIR="$HOME/.opencloud-sync.d"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
DEFAULT_MOUNT_POINT="$HOME/OpenCloud"
DEFAULT_CACHE_SIZE="10"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load main config file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}"
    CACHE_SIZE="${CACHE_SIZE:-$DEFAULT_CACHE_SIZE}"
}

# Load a sync destination config
load_sync_config() {
    local name="$1"
    local config_file="$SYNC_DIR/$name.conf"
    if [ -f "$config_file" ]; then
        source "$config_file"
        return 0
    fi
    return 1
}

# Get all sync destination names
get_sync_names() {
    if [ -d "$SYNC_DIR" ]; then
        ls "$SYNC_DIR"/*.conf 2>/dev/null | xargs -I {} basename {} .conf
    fi
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

# Setup rclone remote configuration (no sync paths)
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

    if [ -z "$server_url" ] || [ -z "$username" ] || [ -z "$password" ]; then
        log_error "Server URL, username, and password are required"
        exit 1
    fi

    # Save config
    cat > "$CONFIG_FILE" <<EOF
MOUNT_POINT="$mount_point"
CACHE_SIZE="$cache_size"
EOF
    load_config
    log_info "Mount point: $MOUNT_POINT"
    log_info "Cache size limit: ${CACHE_SIZE}GB"

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

    echo ""
    log_info "To add sync destinations, run: $0 install <name>"
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

# Run sync for a specific destination
run_sync() {
    local name="$1"
    local config_file="$SYNC_DIR/$name.conf"
    local lock_file="$SYNC_DIR/$name.lock"
    local fail_file="$SYNC_DIR/$name.failures"

    if [ ! -f "$config_file" ]; then
        log_error "Destination '$name' not found"
        return 1
    fi

    source "$config_file"

    # Check for lock file (prevent overlapping syncs)
    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "[$name] Sync already running (PID $lock_pid), skipping"
            return 0
        else
            rm -f "$lock_file"
        fi
    fi

    # Create lock file
    echo $$ > "$lock_file"
    trap "rm -f '$lock_file'" EXIT

    log_info "[$name] Syncing $SYNC_LOCAL <-> $REMOTE_NAME:$SYNC_REMOTE"

    # Track failure count
    local fail_count=0
    if [ -f "$fail_file" ]; then
        fail_count=$(cat "$fail_file")
    fi

    # Run bisync
    if rclone bisync "$SYNC_LOCAL" "$REMOTE_NAME:$SYNC_REMOTE" \
        --create-empty-src-dirs \
        --compare size,modtime \
        --slow-hash-sync-only \
        --resilient \
        -v \
        --log-file="$HOME/.opencloud-sync.log" 2>&1; then
        log_info "[$name] Sync completed successfully"
        rm -f "$fail_file"
    else
        fail_count=$((fail_count + 1))
        echo "$fail_count" > "$fail_file"
        log_error "[$name] Sync failed ($fail_count consecutive). Run: $0 resync $name"
    fi

    rm -f "$lock_file"
    trap - EXIT
}

# Run sync for all destinations
do_sync_all() {
    local names
    names=$(get_sync_names)

    if [ -z "$names" ]; then
        log_error "No sync destinations configured. Run: $0 install <name>"
        exit 1
    fi

    for name in $names; do
        run_sync "$name"
    done
}

# List all sync destinations
do_sync_ls() {
    local names
    names=$(get_sync_names)

    if [ -z "$names" ]; then
        echo "No sync destinations configured."
        echo "Add one with: $0 install <name>"
        return
    fi

    echo "Sync Destinations"
    echo "================="
    echo ""

    for name in $names; do
        source "$SYNC_DIR/$name.conf"
        local plist="$LAUNCHD_DIR/com.opencloud.sync.$name.plist"
        local fail_file="$SYNC_DIR/$name.failures"
        local status="${GREEN}OK${NC}"

        if [ -f "$fail_file" ]; then
            local fails
            fails=$(cat "$fail_file")
            status="${RED}FAILING${NC} ($fails)"
        fi

        echo -e "[$name]"
        echo "  Local:   $SYNC_LOCAL"
        echo "  Remote:  $REMOTE_NAME:$SYNC_REMOTE"
        if [ -f "$plist" ]; then
            echo -e "  Service: ${GREEN}installed${NC}"
        else
            echo -e "  Service: ${YELLOW}not installed${NC}"
        fi
        echo -e "  Status:  $status"
        echo ""
    done
}

# Remove a sync destination from config
do_sync_rm() {
    local name="$1"

    if [ -z "$name" ]; then
        log_error "Usage: $0 sync rm <name>"
        exit 1
    fi

    local config_file="$SYNC_DIR/$name.conf"
    local plist="$LAUNCHD_DIR/com.opencloud.sync.$name.plist"

    if [ ! -f "$config_file" ]; then
        log_error "Destination '$name' not found"
        exit 1
    fi

    # Uninstall service first if exists
    if [ -f "$plist" ]; then
        do_uninstall "$name"
    fi

    # Remove config and related files
    rm -f "$config_file"
    rm -f "$SYNC_DIR/$name.lock"
    rm -f "$SYNC_DIR/$name.failures"

    log_info "Destination '$name' removed"
}

# Resync a specific destination
do_resync() {
    local name="$1"
    local mode="${2:-newer}"

    if [ -z "$name" ]; then
        log_error "Usage: $0 resync <name> [local|remote|newer]"
        exit 1
    fi

    local config_file="$SYNC_DIR/$name.conf"
    if [ ! -f "$config_file" ]; then
        log_error "Destination '$name' not found"
        exit 1
    fi

    source "$config_file"

    local resync_mode
    local conflict_loser=""

    case "$mode" in
        local)
            resync_mode="path1"
            ;;
        remote)
            resync_mode="path2"
            ;;
        newer)
            resync_mode="newer"
            conflict_loser="--conflict-loser num"
            ;;
        *)
            log_error "Invalid mode: $mode"
            echo "Usage: $0 resync <name> [local|remote|newer]"
            echo ""
            echo "Modes:"
            echo "  local  - Local folder is source of truth"
            echo "  remote - Remote folder is source of truth"
            echo "  newer  - Newer file wins (default, keeps backup of older)"
            exit 1
            ;;
    esac

    mkdir -p "$SYNC_LOCAL"

    log_warn "[$name] Running resync with mode: $mode ($resync_mode)"
    log_info "Local:  $SYNC_LOCAL"
    log_info "Remote: $REMOTE_NAME:$SYNC_REMOTE"

    local fail_file="$SYNC_DIR/$name.failures"

    if rclone bisync "$SYNC_LOCAL" "$REMOTE_NAME:$SYNC_REMOTE" \
        --resync \
        --resync-mode "$resync_mode" \
        $conflict_loser \
        --create-empty-src-dirs \
        --compare size,modtime \
        --slow-hash-sync-only \
        --resilient \
        -v \
        --log-file="$HOME/.opencloud-sync.log" 2>&1; then
        log_info "[$name] Resync completed successfully"
        rm -f "$fail_file"
    else
        log_error "[$name] Resync failed. Check $HOME/.opencloud-sync.log"
    fi
}

# Check if launchd job is loaded
is_launchd_loaded() {
    local label="$1"
    launchctl list 2>/dev/null | grep -q "$label"
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
    do_sync_ls

    echo "Logs"
    echo "----"
    echo "Mount log:   ~/.opencloud-mount.log"
    echo "Sync log:    ~/.opencloud-sync.log"
}

# Install a sync destination
do_install() {
    local name="$1"

    if [ -z "$name" ]; then
        log_error "Usage: $0 install <name>"
        echo ""
        echo "Example: $0 install ableton"
        exit 1
    fi

    # Validate name (alphanumeric and dashes only)
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid name. Use only letters, numbers, dashes, and underscores."
        exit 1
    fi

    # Check if remote exists
    if ! rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
        log_error "Remote not configured. Run: $0 setup"
        exit 1
    fi

    mkdir -p "$SYNC_DIR"

    local config_file="$SYNC_DIR/$name.conf"
    local plist="$LAUNCHD_DIR/com.opencloud.sync.$name.plist"
    local label="com.opencloud.sync.$name"

    # Load existing values if destination exists
    local existing_local=""
    local existing_remote=""
    if [ -f "$config_file" ]; then
        source "$config_file"
        existing_local="$SYNC_LOCAL"
        existing_remote="$SYNC_REMOTE"
        log_info "Updating existing destination: $name"
    else
        log_info "Adding sync destination: $name"
    fi

    echo ""

    # Prompt for local path (show existing as default)
    if [ -n "$existing_local" ]; then
        echo -n "Enter local folder path [$existing_local]: "
    else
        echo -n "Enter local folder path (e.g., ~/Music/Ableton): "
    fi
    read -r sync_local
    sync_local="${sync_local/#\~/$HOME}"
    sync_local="${sync_local:-$existing_local}"

    if [ -z "$sync_local" ]; then
        log_error "Local path is required"
        exit 1
    fi

    # Prompt for remote path (show existing as default)
    if [ -n "$existing_remote" ]; then
        echo -n "Enter remote folder path [$existing_remote]: "
    else
        echo -n "Enter remote folder path (e.g., Music/Ableton): "
    fi
    read -r sync_remote
    sync_remote="${sync_remote:-$existing_remote}"

    if [ -z "$sync_remote" ]; then
        log_error "Remote path is required"
        exit 1
    fi

    # Save config
    cat > "$config_file" <<EOF
SYNC_LOCAL="$sync_local"
SYNC_REMOTE="$sync_remote"
EOF

    log_info "Destination configured:"
    echo "  Local:  $sync_local"
    echo "  Remote: $REMOTE_NAME:$sync_remote"

    # Check if initial sync needed
    local bisync_dir="$HOME/.cache/rclone/bisync"
    local needs_resync=true

    # Simple check - if any bisync state exists for this path combo, skip resync prompt
    if [ -d "$bisync_dir" ] && ls "$bisync_dir"/*"${sync_remote//\//_}"* &>/dev/null 2>&1; then
        needs_resync=false
    fi

    if [ "$needs_resync" = true ]; then
        echo ""
        log_warn "Initial sync required"
        echo ""
        echo "Choose sync strategy:"
        echo "  1) newer  - Keep newer file from either side (safer, keeps backup of older)"
        echo "  2) local  - Local folder is source of truth (overwrites remote)"
        echo "  3) remote - Remote folder is source of truth (overwrites local)"
        echo ""
        echo -n "Select strategy [1-3, default=1]: "
        read -r choice

        local mode
        case "$choice" in
            2) mode="local" ;;
            3) mode="remote" ;;
            *) mode="newer" ;;
        esac

        echo ""
        do_resync "$name" "$mode"
    fi

    # Create launchd plist
    echo ""
    log_info "Installing launchd service..."

    local script_path
    script_path=$(realpath "$0")

    mkdir -p "$LAUNCHD_DIR"

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$script_path</string>
        <string>sync</string>
        <string>$name</string>
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
    <string>$HOME/.opencloud-sync-$name.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.opencloud-sync-$name.log</string>
</dict>
</plist>
EOF

    # Unload if already loaded
    if is_launchd_loaded "$label"; then
        launchctl unload "$plist" 2>/dev/null || true
    fi

    # Load service
    launchctl load "$plist"

    log_info "Service installed for '$name'"
    log_info "Sync will run every 60 seconds"
    echo ""
    log_info "View status with: $0 status"
}

# Uninstall a sync destination's launchd service
do_uninstall() {
    local name="$1"

    if [ -z "$name" ]; then
        log_error "Usage: $0 uninstall <name>"
        exit 1
    fi

    local plist="$LAUNCHD_DIR/com.opencloud.sync.$name.plist"
    local label="com.opencloud.sync.$name"

    if [ ! -f "$plist" ]; then
        log_info "Service for '$name' not installed"
        return 0
    fi

    log_info "Uninstalling service for '$name'..."

    if is_launchd_loaded "$label"; then
        launchctl unload "$plist" 2>/dev/null || true
    fi

    rm -f "$plist"
    log_info "Service for '$name' removed"
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
        case "${2:-}" in
            ls)
                do_sync_ls
                ;;
            rm)
                do_sync_rm "${3:-}"
                ;;
            "")
                do_sync_all
                ;;
            *)
                # Sync specific destination
                run_sync "$2"
                ;;
        esac
        ;;
    resync)
        do_resync "${2:-}" "${3:-}"
        ;;
    status)
        show_status
        ;;
    install)
        do_install "${2:-}"
        ;;
    uninstall)
        do_uninstall "${2:-}"
        ;;
    *)
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  setup                  - Configure rclone remote"
        echo "  mount                  - Mount OpenCloud WebDAV"
        echo "  unmount                - Unmount the share"
        echo "  install <name>         - Add sync destination and install service"
        echo "  uninstall <name>       - Remove launchd service for destination"
        echo "  sync                   - Run all syncs"
        echo "  sync <name>            - Run sync for specific destination"
        echo "  sync ls                - List all sync destinations"
        echo "  sync rm <name>         - Remove destination from config"
        echo "  resync <name> [mode]   - Full resync (mode: local|remote|newer)"
        echo "  status                 - Show status"
        exit 1
        ;;
esac

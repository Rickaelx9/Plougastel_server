#!/bin/bash
set -e  # Exit immediately on error

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.actual_backup.env" ]; then
    # Expected vars are documented below in the template
    # shellcheck source=/dev/null
    source "$HOME/borg/.actual_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.actual_backup.env"
    exit 1
fi

echo "### Starting Actual Backup Process ###"

# --- DEFAULTS & PATHS ---
ACTUAL_DATA_PATH="${ACTUAL_DATA_PATH:-$HOME/actual/data}"
REPO_UNENCRYPTED="${UNENCRYPTED_ACTUAL_BACKUP_PATH:-}"
REPO_ENCRYPTED="${ENCRYPTED_ACTUAL_BACKUP_PATH:-}"
ARCHIVE_NAME="actual-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="${ACTUAL_PRUNE_ARGS:---keep-daily=7 --keep-weekly=4 --keep-monthly=6}"

# Optional docker compose hints (service name and compose dir/file)
ACTUAL_SERVICE="${ACTUAL_SERVICE:-actual}"
ACTUAL_COMPOSE_DIR="${ACTUAL_COMPOSE_DIR:-$HOME/actual}"
ACTUAL_COMPOSE_FILE="${ACTUAL_COMPOSE_FILE:-$ACTUAL_COMPOSE_DIR/docker-compose.yml}"

# Optional rclone target (only used if non-empty)
RCLONE_REMOTE="${RCLONE_ACTUAL_REMOTE_PATH:-}"

# --- LIGHT SYNC (optional, best-effort) ---
# If docker compose is present and compose file exists, try a gentle sync/flush
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f "$ACTUAL_COMPOSE_FILE" ]; then
    echo "[actual-backup] docker compose detected. Attempting a light sync on service: $ACTUAL_SERVICE"
    # Best-effort: ask container to flush OS buffers if bash is available (non-fatal if it fails)
    docker compose -f "$ACTUAL_COMPOSE_FILE" exec -T "$ACTUAL_SERVICE" sh -c 'sync || true' || true
else
    echo "[actual-backup] docker compose not available (or compose file missing). Skipping light sync."
fi

# --- BUILD A CONSISTENT SNAPSHOT IN /tmp ---
SNAP_BASE="$(mktemp -d /tmp/actual-snapshot.XXXXXX)"
SNAP_DATA="$SNAP_BASE/data"
mkdir -p "$SNAP_DATA/server-files" "$SNAP_DATA/user-files"

echo "[actual-backup] Creating snapshot at: $SNAP_DATA"

# If sqlite3 exists, use .backup for SQLite files; otherwise copy as-is.
if command -v sqlite3 >/dev/null 2>&1; then
    echo "[actual-backup] sqlite3 detected: using .backup for SQLite files."
    # server-files/*.sqlite
    for db in "$ACTUAL_DATA_PATH/server-files/"*.sqlite; do
        [ -e "$db" ] || continue
        base="$(basename "$db")"
        sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; .backup '$SNAP_DATA/server-files/$base'"
    done
    # user-files/*.sqlite
    for db in "$ACTUAL_DATA_PATH/user-files/"*.sqlite; do
        [ -e "$db" ] || continue
        base="$(basename "$db")"
        sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; .backup '$SNAP_DATA/user-files/$base'"
    done
else
    echo "[actual-backup] sqlite3 not found: copying SQLite files directly (still acceptable)."
    rsync -a --delete "$ACTUAL_DATA_PATH/server-files/" "$SNAP_DATA/server-files/" || true
    rsync -a --delete "$ACTUAL_DATA_PATH/user-files/"   "$SNAP_DATA/user-files/"   || true
fi

# Always copy blob files and the rest of the tree
rsync -a --delete --exclude 'server-files/*.sqlite' --exclude 'user-files/*.sqlite' \
      "$ACTUAL_DATA_PATH/" "$SNAP_DATA/"

SOURCE_PATH="$SNAP_DATA"

# --- INITIALIZE REPOSITORIES (IMPROVED CHECK) ---
init_repo_if_needed() {
    local repo_path="$1"
    local enc_mode="$2" # "none" or "repokey-blake2"

    [ -n "$repo_path" ] || return 0
    mkdir -p "$repo_path" || true

    if [ ! -f "$repo_path/config" ]; then
        echo "Initializing repository at $repo_path (encryption: $enc_mode)..."
        # Use BORG_PASSPHRASE from env when encryption != none
        if [ "$enc_mode" = "none" ]; then
            borg init --encryption=none "$repo_path"
        else
            if [ -z "${BORG_PASSPHRASE:-}" ]; then
                echo "ERROR: BORG_PASSPHRASE is required to initialize encrypted repository: $repo_path"
                exit 1
            fi
            BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey-blake2 "$repo_path"
        fi
    fi
}

[ -n "$REPO_UNENCRYPTED" ] && init_repo_if_needed "$REPO_UNENCRYPTED" "none"
[ -n "$REPO_ENCRYPTED"   ] && init_repo_if_needed "$REPO_ENCRYPTED"   "repokey-blake2"

# --- CREATE LOCAL BACKUPS IN PARALLEL ---
echo "--> Starting local Actual backups in parallel..."

pids=()

if [ -n "$REPO_UNENCRYPTED" ]; then
(
    echo "Starting UNENCRYPTED Actual backup..."
    borg create --stats --progress \
        "$REPO_UNENCRYPTED::$ARCHIVE_NAME" \
        "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted Actual backup complete."
) &
pids+=($!)
fi

if [ -n "$REPO_ENCRYPTED" ]; then
(
    echo "Starting ENCRYPTED Actual backup..."
    # Ensure passphrase is set when using encrypted repo
    if [ -z "${BORG_PASSPHRASE:-}" ]; then
        echo "ERROR: BORG_PASSPHRASE must be set for encrypted backups."
        exit 1
    fi
    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create --stats --progress \
        "$REPO_ENCRYPTED::$ARCHIVE_NAME" \
        "$SOURCE_PATH"
    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted Actual backup complete."
) &
pids+=($!)
fi

# If neither repo is set, fail early
if [ ${#pids[@]} -eq 0 ]; then
    echo "ERROR: Neither UNENCRYPTED_ACTUAL_BACKUP_PATH nor ENCRYPTED_ACTUAL_BACKUP_PATH is set."
    rm -rf "$SNAP_BASE"
    exit 1
fi

# Wait for both (or one) to finish
for pid in "${pids[@]}"; do wait "$pid"; done
echo "--> All local Actual backups have finished."

# --- SYNCHRONIZE OFFSITE BACKUP (ENCRYPTED) ---
if [ -n "$RCLONE_REMOTE" ] && [ -n "$REPO_ENCRYPTED" ]; then
    echo "--> Synchronizing encrypted Actual repository to remote with rclone..."
    rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_REMOTE"
    echo "✅ Off-site Actual synchronization complete."
else
    echo "[actual-backup] No rclone remote or no encrypted repo configured. Skipping off-site sync."
fi

# --- CLEANUP SNAPSHOT ---
rm -rf "$SNAP_BASE"
echo "### 🎉 All Actual backup tasks finished successfully! ###"


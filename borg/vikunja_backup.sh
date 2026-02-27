#!/bin/bash
set -e  # Exit immediately on error

# --- AJOUT GESTION ERREUR ---
source "$HOME/borg/error_handler.sh"
# ----------------------------

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.vikunja_backup.env" ]; then
    # shellcheck source=/dev/null
    source "$HOME/borg/.vikunja_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.vikunja_backup.env"
    exit 1
fi

echo "### Starting Vikunja Backup Process ###"

# --- DEFAULTS & PATHS ---
VIKUNJA_DATA_PATH="${VIKUNJA_DATA_PATH:-$HOME/vikunja}"
REPO_UNENCRYPTED="${UNENCRYPTED_VIKUNJA_BACKUP_PATH:-}"
REPO_ENCRYPTED="${ENCRYPTED_VIKUNJA_BACKUP_PATH:-}"
ARCHIVE_NAME="vikunja-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="${VIKUNJA_PRUNE_ARGS:---keep-daily=7 --keep-weekly=4 --keep-monthly=6}"

VIKUNJA_COMPOSE_FILE="${VIKUNJA_COMPOSE_FILE:-$VIKUNJA_DATA_PATH/docker-compose.yml}"
RCLONE_REMOTE="${RCLONE_VIKUNJA_REMOTE_PATH:-}"

# --- BUILD A CONSISTENT SNAPSHOT IN /tmp ---
SNAP_BASE="$(mktemp -d /tmp/vikunja-snapshot.XXXXXX)"

echo "[vikunja-backup] Creating snapshot at: $SNAP_BASE"

# 1. Backup the PostgreSQL Database using pg_dump
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f "$VIKUNJA_COMPOSE_FILE" ]; then
    echo "[vikunja-backup] Dumping Postgres database from the 'db' container..."
    # Execute pg_dump inside the container and pipe the output to a local .sql file
    # Uses the username 'vikunja' and database 'vikunja' as defined in your compose file
    docker compose -f "$VIKUNJA_COMPOSE_FILE" exec -T db pg_dump -U vikunja vikunja > "$SNAP_BASE/vikunja_db.sql"
    echo "[vikunja-backup] Database dump successful."
else
    echo "ERROR: docker compose not available or compose file missing at $VIKUNJA_COMPOSE_FILE. Cannot backup database!"
    rm -rf "$SNAP_BASE"
    exit 1
fi

# 2. Backup Vikunja Files (attachments, avatars, etc.)
echo "[vikunja-backup] Copying user files..."
if [ -d "$VIKUNJA_DATA_PATH/files" ]; then
    mkdir -p "$SNAP_BASE/files"
    rsync -a --delete "$VIKUNJA_DATA_PATH/files/" "$SNAP_BASE/files/"
else
    echo "[vikunja-backup] Warning: files directory not found at $VIKUNJA_DATA_PATH/files"
fi

# 3. Backup docker-compose.yml (contains JWT secrets and config)
echo "[vikunja-backup] Copying docker-compose.yml..."
cp "$VIKUNJA_COMPOSE_FILE" "$SNAP_BASE/"

SOURCE_PATH="$SNAP_BASE"

# --- INITIALIZE REPOSITORIES ---
init_repo_if_needed() {
    local repo_path="$1"
    local enc_mode="$2"

    [ -n "$repo_path" ] || return 0
    mkdir -p "$repo_path" || true

    if [ ! -f "$repo_path/config" ]; then
        echo "Initializing repository at $repo_path (encryption: $enc_mode)..."
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
echo "--> Starting local Vikunja backups in parallel..."

pids=()

if [ -n "$REPO_UNENCRYPTED" ]; then
(
    echo "Starting UNENCRYPTED Vikunja backup..."
    borg create --stats --progress \
        "$REPO_UNENCRYPTED::$ARCHIVE_NAME" \
        "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted Vikunja backup complete."
) &
pids+=($!)
fi

if [ -n "$REPO_ENCRYPTED" ]; then
(
    echo "Starting ENCRYPTED Vikunja backup..."
    if [ -z "${BORG_PASSPHRASE:-}" ]; then
        echo "ERROR: BORG_PASSPHRASE must be set for encrypted backups."
        exit 1
    fi
    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create --stats --progress \
        "$REPO_ENCRYPTED::$ARCHIVE_NAME" \
        "$SOURCE_PATH"
    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted Vikunja backup complete."
) &
pids+=($!)
fi

if [ ${#pids[@]} -eq 0 ]; then
    echo "ERROR: Neither UNENCRYPTED_VIKUNJA_BACKUP_PATH nor ENCRYPTED_VIKUNJA_BACKUP_PATH is set."
    rm -rf "$SNAP_BASE"
    exit 1
fi

for pid in "${pids[@]}"; do wait "$pid"; done
echo "--> All local Vikunja backups have finished."

# --- SYNCHRONIZE OFFSITE BACKUP (ENCRYPTED) ---
if [ -n "$RCLONE_REMOTE" ] && [ -n "$REPO_ENCRYPTED" ]; then
    echo "--> Synchronizing encrypted Vikunja repository to remote with rclone..."
    rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_REMOTE"
    echo "✅ Off-site Vikunja synchronization complete."
else
    echo "[vikunja-backup] No rclone remote or no encrypted repo configured. Skipping off-site sync."
fi

# --- CLEANUP SNAPSHOT ---
rm -rf "$SNAP_BASE"
echo "### 🎉 All Vikunja backup tasks finished successfully! ###"

#!/bin/bash
set -e  # Exit immediately on error

# --- AJOUT GESTION ERREUR ---
source "$HOME/borg/error_handler.sh"
# ----------------------------

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
REPO_ENCRYPTED="${ENCRYPTED_ACTUAL_BACKUP_PATH:-}"
ARCHIVE_NAME="actual-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="${ACTUAL_PRUNE_ARGS:---keep-daily=7 --keep-weekly=4 --keep-monthly=6}"

# Optional docker compose hints (service name and compose dir/file)
ACTUAL_SERVICE="${ACTUAL_SERVICE:-actual}"
ACTUAL_COMPOSE_DIR="${ACTUAL_COMPOSE_DIR:-$HOME/actual}"
ACTUAL_COMPOSE_FILE="${ACTUAL_COMPOSE_FILE:-$ACTUAL_COMPOSE_DIR/docker-compose.yml}"

# Optional rclone target (only used if non-empty)
RCLONE_REMOTE="${RCLONE_ACTUAL_REMOTE_PATH:-}"

# Initialisation de la variable pour le trap
SNAP_BASE=""

# --- Function to ensure cleanup happens even if script fails ---
cleanup_and_handle_exit() {
    local exit_code=$? # On capture le code de sortie immédiatement
    set +e # <--- Désactive l'arrêt sur erreur pour garantir le nettoyage et l'email

    echo "--> Running cleanup..."
    if [ -n "$SNAP_BASE" ] && [ -d "$SNAP_BASE" ]; then
        rm -rf "$SNAP_BASE"
    fi
    echo "--> Cleanup complete."

    # On appelle le gestionnaire d'erreur global (qui s'occupe du mail)
    (exit $exit_code) # Astuce pour restaurer le code d'erreur
    handle_exit
}

# On met en place le trap
trap cleanup_and_handle_exit EXIT

# Vérification stricte avant de commencer
if [ -z "$REPO_ENCRYPTED" ]; then
    echo "ERROR: ENCRYPTED_ACTUAL_BACKUP_PATH is not set."
    exit 1
fi
if [ -z "${BORG_PASSPHRASE:-}" ]; then
    echo "ERROR: BORG_PASSPHRASE must be set for encrypted backups."
    exit 1
fi

# --- LIGHT SYNC (optional, best-effort) ---
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f "$ACTUAL_COMPOSE_FILE" ]; then
    echo "[actual-backup] docker compose detected. Attempting a light sync on service: $ACTUAL_SERVICE"
    docker compose -f "$ACTUAL_COMPOSE_FILE" exec -T "$ACTUAL_SERVICE" sh -c 'sync || true' || true
else
    echo "[actual-backup] docker compose not available (or compose file missing). Skipping light sync."
fi

# --- BUILD A CONSISTENT SNAPSHOT IN /tmp ---
SNAP_BASE="$(mktemp -d /tmp/actual-snapshot.XXXXXX)"
SNAP_DATA="$SNAP_BASE/data"
mkdir -p "$SNAP_DATA/server-files" "$SNAP_DATA/user-files"

echo "[actual-backup] Creating snapshot at: $SNAP_DATA"

if command -v sqlite3 >/dev/null 2>&1; then
    echo "[actual-backup] sqlite3 detected: using .backup for SQLite files."
    for db in "$ACTUAL_DATA_PATH/server-files/"*.sqlite; do
        [ -e "$db" ] || continue
        base="$(basename "$db")"
        sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; .backup '$SNAP_DATA/server-files/$base'"
    done
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

# --- INITIALIZE REPOSITORY ---
mkdir -p "$REPO_ENCRYPTED" || true
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED repository at $REPO_ENCRYPTED..."
    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- CREATE LOCAL BACKUP ---
echo "--> Starting local Actual encrypted backup..."

BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create --stats --progress \
    "$REPO_ENCRYPTED::$ARCHIVE_NAME" \
    "$SOURCE_PATH"

echo "--> Pruning old backups..."
BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"

echo "✅ Encrypted Actual backup complete."

# --- SYNCHRONIZE OFFSITE BACKUP (ENCRYPTED) ---
if [ -n "$RCLONE_REMOTE" ]; then
    echo "--> Synchronizing encrypted Actual repository to remote with rclone..."
    rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_REMOTE"
    echo "✅ Off-site Actual synchronization complete."
else
    echo "[actual-backup] No rclone remote configured. Skipping off-site sync."
fi

echo "### 🎉 All Actual backup tasks finished successfully! ###"

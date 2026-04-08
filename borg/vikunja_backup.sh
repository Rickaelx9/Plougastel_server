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
REPO_ENCRYPTED="${ENCRYPTED_VIKUNJA_BACKUP_PATH:-}"
ARCHIVE_NAME="vikunja-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="${VIKUNJA_PRUNE_ARGS:---keep-daily=7 --keep-weekly=4 --keep-monthly=6}"

VIKUNJA_COMPOSE_FILE="${VIKUNJA_COMPOSE_FILE:-$VIKUNJA_DATA_PATH/docker-compose.yml}"
RCLONE_REMOTE="${RCLONE_VIKUNJA_REMOTE_PATH:-}"

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
    echo "ERROR: ENCRYPTED_VIKUNJA_BACKUP_PATH is not set."
    exit 1
fi
if [ -z "${BORG_PASSPHRASE:-}" ]; then
    echo "ERROR: BORG_PASSPHRASE must be set for encrypted backups."
    exit 1
fi

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

# --- INITIALIZE REPOSITORY ---
mkdir -p "$REPO_ENCRYPTED" || true
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED repository at $REPO_ENCRYPTED..."
    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- CREATE LOCAL BACKUP ---
echo "--> Starting local Vikunja encrypted backup..."

BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create --stats --progress \
    "$REPO_ENCRYPTED::$ARCHIVE_NAME" \
    "$SOURCE_PATH"

echo "--> Pruning old backups..."
BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"

echo "✅ Encrypted Vikunja backup complete."

# --- SYNCHRONIZE OFFSITE BACKUP (ENCRYPTED) ---
if [ -n "$RCLONE_REMOTE" ]; then
    echo "--> Synchronizing encrypted Vikunja repository to remote with rclone..."
    rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_REMOTE"
    echo "✅ Off-site Vikunja synchronization complete."
else
    echo "[vikunja-backup] No rclone remote configured. Skipping off-site sync."
fi

echo "### 🎉 All Vikunja backup tasks finished successfully! ###"

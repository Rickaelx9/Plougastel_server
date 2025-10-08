#!/bin/bash
set -e # Exit immediately if a command fails.

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.paperless_backup.env" ]; then
    source "$HOME/borg/.paperless_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.paperless_backup.env"
    exit 1
fi

# --- PATHS & SETTINGS ---
SOURCE_PATH="$PAPERLESS_DATA_PATH"
# Create a temporary directory inside the source for the DB dump
DB_DUMP_DIR="$SOURCE_PATH/db_dump"
DB_DUMP_TARGET="$DB_DUMP_DIR/paperless-db.sql"

REPO_UNENCRYPTED="$UNENCRYPTED_PAPERLESS_BACKUP_PATH"
REPO_ENCRYPTED="$ENCRYPTED_PAPERLESS_BACKUP_PATH"
ARCHIVE_NAME="paperless-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="--keep-daily=7 --keep-weekly=4 --keep-monthly=6"

echo "### Starting Paperless-ngx Backup Process ###"

# --- STEP 1: DUMP THE POSTGRESQL DATABASE ---
echo "--> Dumping the Paperless-ngx database..."
mkdir -p "$DB_DUMP_DIR"
docker exec -t "$PAPERLESS_DB_CONTAINER" pg_dumpall -c -U "$PAPERLESS_DB_USER" > "$DB_DUMP_TARGET"
echo "✅ Database dump complete."

# --- STEP 2: INITIALIZE REPOSITORIES (IMPROVED CHECK) ---
if [ ! -f "$REPO_UNENCRYPTED/config" ]; then
    echo "Initializing UNENCRYPTED Paperless repository..."
    borg init --encryption=none "$REPO_UNENCRYPTED"
fi
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED Paperless repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- STEP 3: CREATE LOCAL BACKUPS IN PARALLEL ---
echo "--> Starting local Paperless backups in parallel..."

(
    echo "Starting unencrypted Paperless backup..."
    borg create --stats --progress "$REPO_UNENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH/data" "$SOURCE_PATH/media" "$SOURCE_PATH/db_dump"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted Paperless backup complete."
) &

(
    echo "Starting encrypted Paperless backup..."
    borg create --stats --progress "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH/data" "$SOURCE_PATH/media" "$SOURCE_PATH/db_dump"
    borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted Paperless backup complete."
) &

wait
echo "--> All local Paperless backups have finished."

# --- Clean up the temporary database dump
rm -rf "$DB_DUMP_DIR"

# --- STEP 4: SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
echo "--> Synchronizing encrypted Paperless repository to Google Drive..."
rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_PAPERLESS_REMOTE_PATH"
echo "✅ Off-site Paperless synchronization complete."

echo "### 🎉 All Paperless backup tasks finished successfully! ###"

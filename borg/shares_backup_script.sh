#!/bin/bash
set -e # Exit immediately if a command fails.

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.shares_backup.env" ]; then
    source "$HOME/borg/.shares_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.shares_backup.env"
    exit 1
fi

# --- PATHS & SETTINGS ---
SOURCE_PATH="$SHARES_DATA_PATH"
REPO_UNENCRYPTED="$UNENCRYPTED_SHARES_BACKUP_PATH"
REPO_ENCRYPTED="$ENCRYPTED_SHARES_BACKUP_PATH"
ARCHIVE_NAME="shares_and_db-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="--keep-daily=7 --keep-weekly=4 --keep-monthly=6"

# --- Function to ensure cleanup happens even if script fails ---
cleanup() {
    echo "--> Running cleanup..."
    # Only try to start the container if the script is exiting due to an error.
    # Otherwise, just remove the temp file.
    if [ "$?" != "0" ]; then
      echo "Script failed. Ensuring container is running..."
      docker compose --project-directory "$FILEBROWSER_PROJECT_PATH" start filebrowser || echo "Could not start container."
    fi

    # Always remove the temporary database copy
    rm -f "$DB_BACKUP_FILE"
    echo "--> Cleanup complete."
}
trap cleanup EXIT

echo "### Starting Backup Process ###"

# --- INITIALIZE REPOSITORIES ---
if [ ! -f "$REPO_UNENCRYPTED/config" ]; then
    echo "Initializing UNENCRYPTED repository..."
    borg init --encryption=none "$REPO_UNENCRYPTED"
fi
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- SAFELY COPY THE DATABASE ---
echo "--> Preparing database for backup..."
echo "Stopping FileBrowser container to ensure data consistency..."
docker compose --project-directory "$FILEBROWSER_PROJECT_PATH" stop filebrowser

echo "Copying database file to temporary location..."
cp "$DB_SOURCE_FILE" "$DB_BACKUP_FILE"

echo "Restarting FileBrowser container... (Downtime is over)"
docker compose --project-directory "$FILEBROWSER_PROJECT_PATH" start filebrowser
echo "✅ Database is prepared and service is back online."


# --- CREATE LOCAL BACKUPS IN PARALLEL ---
echo "--> Starting local backups in parallel (Shares + Database)..."

(
    echo "Starting unencrypted backup..."
    # MODIFIED: Added --exclude flag to skip jellyfin_media
    borg create --stats --progress --exclude "$SOURCE_PATH/torrent" "$REPO_UNENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH" "$DB_BACKUP_FILE"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted backup complete."
) &

(
    echo "Starting encrypted backup..."
    # MODIFIED: Added --exclude flag to skip jellyfin_media
    borg create --stats --progress --exclude "$SOURCE_PATH/torrent" "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH" "$DB_BACKUP_FILE"
    borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted backup complete."
) &

wait
echo "--> All local backups have finished."

# --- SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
echo "--> Synchronizing encrypted repository to Google Drive..."
rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_SHARES_REMOTE_PATH"
echo "✅ Off-site synchronization complete."

echo "### 🎉 All backup tasks finished successfully! ###"

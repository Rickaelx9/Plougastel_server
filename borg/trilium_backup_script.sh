#!/bin/bash
set -e # Exit immediately if a command fails.

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.trilium_backup.env" ]; then
    source "$HOME/borg/.trilium_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.trilium_backup.env"
    exit 1
fi

# --- PATHS & SETTINGS ---
SOURCE_PATH="$TRILIUM_DATA_PATH"
REPO_UNENCRYPTED="$UNENCRYPTED_TRILIUM_BACKUP_PATH"
REPO_ENCRYPTED="$ENCRYPTED_TRILIUM_BACKUP_PATH"
ARCHIVE_NAME="trilium-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="--keep-daily=7 --keep-weekly=4 --keep-monthly=6" # More frequent for notes

echo "### Starting Trilium Backup Process ###"

# --- INITIALIZE REPOSITORIES (IMPROVED CHECK) ---
# This new check looks for the 'config' file to see if the repo is truly initialized.
if [ ! -f "$REPO_UNENCRYPTED/config" ]; then
    echo "Initializing UNENCRYPTED Trilium repository..."
    borg init --encryption=none "$REPO_UNENCRYPTED"
fi
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED Trilium repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- CREATE LOCAL BACKUPS IN PARALLEL ---
echo "--> Starting local Trilium backups in parallel..."

(
    echo "Starting unencrypted Trilium backup..."
    borg create --stats --progress --exclude-from <(echo "$SOURCE_PATH/log") --exclude-from <(echo "$SOURCE_PATH/tmp") "$REPO_UNENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted Trilium backup complete."
) &

(
    echo "Starting encrypted Trilium backup..."
    borg create --stats --progress --exclude-from <(echo "$SOURCE_PATH/log") --exclude-from <(echo "$SOURCE_PATH/tmp") "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted Trilium backup complete."
) &

wait
echo "--> All local Trilium backups have finished."

# --- SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
echo "--> Synchronizing encrypted Trilium repository to Google Drive..."
rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_TRILIUM_REMOTE_PATH"
echo "✅ Off-site Trilium synchronization complete."

echo "### 🎉 All Trilium backup tasks finished successfully! ###"

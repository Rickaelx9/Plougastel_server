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
ARCHIVE_NAME="shares-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="--keep-daily=7 --keep-weekly=4 --keep-monthly=6"

echo "### Starting Shares Backup Process ###"

# --- INITIALIZE REPOSITORIES (IMPROVED CHECK) ---
if [ ! -f "$REPO_UNENCRYPTED/config" ]; then
    echo "Initializing UNENCRYPTED Shares repository..."
    borg init --encryption=none "$REPO_UNENCRYPTED"
fi
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED Shares repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- CREATE LOCAL BACKUPS IN PARALLEL ---
echo "--> Starting local Shares backups in parallel..."

(
    echo "Starting unencrypted Shares backup..."
    borg create --stats --progress "$REPO_UNENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted Shares backup complete."
) &

(
    echo "Starting encrypted Shares backup..."
    borg create --stats --progress "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted Shares backup complete."
) &

wait
echo "--> All local Shares backups have finished."

# --- SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
echo "--> Synchronizing encrypted Shares repository to Google Drive..."
rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_SHARES_REMOTE_PATH"
echo "✅ Off-site Shares synchronization complete."

echo "### 🎉 All Shares backup tasks finished successfully! ###"

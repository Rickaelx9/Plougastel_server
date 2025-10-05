#!/bin/bash
set -e # Exit immediately if a command fails.

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.vaultwarden_backup.env" ]; then
    source "$HOME/borg/.vaultwarden_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.vaultwarden_backup.env"
    exit 1
fi

# --- PATHS & SETTINGS ---
SOURCE_PATH="$VAULTWARDEN_DATA_PATH"
REPO_UNENCRYPTED="$UNENCRYPTED_VW_BACKUP_PATH"
REPO_ENCRYPTED="$ENCRYPTED_VW_BACKUP_PATH"
ARCHIVE_NAME="vaultwarden-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="--keep-daily=14 --keep-weekly=8 --keep-monthly=12" # Keep more backups for VW

echo "### Starting Vaultwarden Backup Process ###"

# --- INITIALIZE REPOSITORIES (IMPROVED CHECK) ---
if [ ! -f "$REPO_UNENCRYPTED/config" ]; then
    echo "Initializing UNENCRYPTED Vaultwarden repository..."
    borg init --encryption=none "$REPO_UNENCRYPTED"
fi
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED Vaultwarden repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- CREATE LOCAL BACKUPS IN PARALLEL ---
echo "--> Starting local Vaultwarden backups in parallel..."

(
    echo "Starting unencrypted Vaultwarden backup..."
    borg create --stats --progress "$REPO_UNENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
    echo "✅ Unencrypted Vaultwarden backup complete."
) &

(
    echo "Starting encrypted Vaultwarden backup..."
    borg create --stats --progress "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"
    borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
    echo "✅ Encrypted Vaultwarden backup complete."
) &

wait
echo "--> All local Vaultwarden backups have finished."

# --- SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
echo "--> Synchronizing encrypted Vaultwarden repository to Google Drive..."
rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_VW_REMOTE_PATH"
echo "✅ Off-site Vaultwarden synchronization complete."

echo "### 🎉 All Vaultwarden backup tasks finished successfully! ###"

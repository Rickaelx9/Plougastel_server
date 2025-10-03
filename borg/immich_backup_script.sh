#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- SCRIPT CONFIGURATION ---
# Set to 'true' to run in test mode using temporary directories.
# Set to 'false' to run on your actual Immich data.
TEST_MODE=false

# --- LOAD ENVIRONMENT VARIABLES ---
# Source the configuration file with our paths and passphrase.
# The script will fail if the file doesn't exist.
if [ -f "$HOME/borg/.immich_backup.env" ]; then
    source "$HOME/borg/.immich_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.immich_backup.env"
    exit 1
fi

# --- PATHS & SETTINGS (Conditional based on TEST_MODE) ---
if [ "$TEST_MODE" = true ]; then
    echo "--- RUNNING IN TEST MODE ---"
    # Override paths to use our temporary test environment
    SOURCE_PATH="/tmp/fake_immich"
    DB_DUMP_TARGET="$SOURCE_PATH/database-backup/immich-database.sql"
    REPO_UNENCRYPTED="/tmp/backup_unencrypted/borg_repo"
    REPO_ENCRYPTED="/tmp/backup_encrypted/borg_repo"
    # In test mode, we won't actually dump the database
    DB_DUMP_COMMAND="echo 'This is a fake DB dump for testing' > $DB_DUMP_TARGET"
else
    echo "--- RUNNING IN PRODUCTION MODE ---"
    SOURCE_PATH="$IMMICH_DATA_PATH"
    DB_DUMP_TARGET="$SOURCE_PATH/database-backup/immich-database.sql"
    REPO_UNENCRYPTED="$UNENCRYPTED_BACKUP_PATH"
    REPO_ENCRYPTED="$ENCRYPTED_BACKUP_PATH"
    DB_DUMP_COMMAND="docker exec -t $IMMICH_DB_CONTAINER pg_dumpall --clean --if-exists --username=$DB_USERNAME > $DB_DUMP_TARGET"
fi

# Archive name based on the current date and time
ARCHIVE_NAME="{now:%Y-%m-%d_%H-%M-%S}"

# Borg Prune Settings (keep 4 weekly, 3 monthly)
PRUNE_ARGS="--keep-weekly=4 --keep-monthly=3"

# --- STEP 0: INITIALIZE REPOSITORIES (if they don't exist) ---
echo "Checking for repositories..."
# Unencrypted Repo
if [ ! -d "$REPO_UNENCRYPTED" ]; then
    echo "Initializing UNENCRYPTED Borg repository..."
    borg init --encryption=none "$REPO_UNENCRYPTED"
fi

# Encrypted Repo
if [ ! -d "$REPO_ENCRYPTED" ]; then
    echo "Initializing ENCRYPTED Borg repository..."
    # The passphrase is automatically used from the BORG_PASSPHRASE environment variable
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi


# --- STEP 1: BACKUP DATABASE ---
echo "Backing up Immich database..."
mkdir -p "$(dirname "$DB_DUMP_TARGET")"
eval $DB_DUMP_COMMAND
echo "✅ Database backup complete."


# --- STEP 2: CREATE LOCAL UNENCRYPTED BACKUP (1TB HDD) ---
echo "Creating unencrypted backup archive..."
borg create --stats --progress \
    --exclude "$SOURCE_PATH/thumbs" \
    --exclude "$SOURCE_PATH/encoded-video" \
    "$REPO_UNENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"

echo "Pruning unencrypted repository..."
borg prune $PRUNE_ARGS "$REPO_UNENCRYPTED"
echo "✅ Unencrypted backup complete."


# --- STEP 3: CREATE LOCAL ENCRYPTED BACKUP (2TB HDD) ---
echo "Creating encrypted backup archive..."
borg create --stats --progress \
    --exclude "$SOURCE_PATH/thumbs" \
    --exclude "$SOURCE_PATH/encoded-video" \
    "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"

echo "Pruning encrypted repository..."
borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
echo "✅ Encrypted backup complete."


# --- STEP 4: SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE (NEW EFFICIENT METHOD) ---
echo "Starting off-site synchronization process..."

# Determine the correct rclone destination based on TEST_MODE
if [ "$TEST_MODE" = true ]; then
    RCLONE_DESTINATION="$RCLONE_TEST_REMOTE_PATH"
    echo "🧪 Off-site Test Mode: Syncing to '$RCLONE_DESTINATION'"
else
    RCLONE_DESTINATION="$RCLONE_REMOTE_PATH"
    echo "🚀 Off-site Production Mode: Syncing to '$RCLONE_DESTINATION'"
fi

# Synchronize the local encrypted repo with the remote destination.
# This only uploads the changes, saving massive amounts of space and bandwidth.
rclone sync \
    --progress \
    "$REPO_ENCRYPTED" "$RCLONE_DESTINATION"

echo "✅ Off-site synchronization complete."


echo "🎉 All backup tasks finished successfully! 🎉"

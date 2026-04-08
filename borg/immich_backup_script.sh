#!/bin/bash
set -e  # Exit immediately on error

# --- AJOUT GESTION ERREUR ---
source "$HOME/borg/error_handler.sh"
# ----------------------------

# --- SCRIPT CONFIGURATION ---
# Set to 'true' to run in test mode using temporary directories.
# Set to 'false' to run on your actual Immich data.
TEST_MODE=false

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.immich_backup.env" ]; then
    source "$HOME/borg/.immich_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.immich_backup.env"
    exit 1
fi

# --- Function to ensure cleanup happens even if script fails ---
cleanup_and_handle_exit() {
    local exit_code=$? # On capture le code de sortie immédiatement
    set +e # <--- Désactive l'arrêt sur erreur pour garantir l'envoi du mail

    echo "--> Running cleanup..."
    # Ajoutez ici d'éventuelles commandes de nettoyage si besoin à l'avenir
    echo "--> Cleanup complete."

    # On appelle le gestionnaire d'erreur global (qui s'occupe du mail)
    (exit $exit_code) # Astuce pour restaurer le code d'erreur
    handle_exit
}

# On met en place le trap
trap cleanup_and_handle_exit EXIT

# --- PATHS & SETTINGS (Conditional based on TEST_MODE) ---
if [ "$TEST_MODE" = true ]; then
    echo "--- RUNNING IN TEST MODE ---"
    # Override paths to use our temporary test environment
    SOURCE_PATH="/tmp/fake_immich"
    DB_DUMP_TARGET="$SOURCE_PATH/database-backup/immich-database.sql"
    REPO_ENCRYPTED="/tmp/backup_encrypted/borg_repo"
    # In test mode, we won't actually dump the database
    DB_DUMP_COMMAND="echo 'This is a fake DB dump for testing' > $DB_DUMP_TARGET"
else
    echo "--- RUNNING IN PRODUCTION MODE ---"
    SOURCE_PATH="$IMMICH_DATA_PATH"
    DB_DUMP_TARGET="$SOURCE_PATH/database-backup/immich-database.sql"
    REPO_ENCRYPTED="$ENCRYPTED_BACKUP_PATH"
    DB_DUMP_COMMAND="docker exec -t $IMMICH_DB_CONTAINER pg_dumpall --clean --if-exists --username=$DB_USERNAME > $DB_DUMP_TARGET"
fi

# Archive name based on the current date and time
ARCHIVE_NAME="{now:%Y-%m-%d_%H-%M-%S}"

# Borg Prune Settings (keep 4 weekly, 3 monthly)
PRUNE_ARGS="--keep-weekly=4 --keep-monthly=3"

# --- STEP 0: INITIALIZE REPOSITORY (if it doesn't exist) ---
echo "Checking for encrypted repository..."
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED Immich repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi


# --- STEP 1: BACKUP DATABASE ---
echo "Backing up Immich database..."
mkdir -p "$(dirname "$DB_DUMP_TARGET")"
eval $DB_DUMP_COMMAND
echo "✅ Database backup complete."


# --- STEP 2: CREATE LOCAL ENCRYPTED BACKUP ---
echo "Creating encrypted backup archive..."
borg create --stats --progress \
    --exclude "$SOURCE_PATH/thumbs" \
    --exclude "$SOURCE_PATH/encoded-video" \
    "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH"

echo "Pruning encrypted repository..."
borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"
echo "✅ Encrypted backup complete."


# --- STEP 3: SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
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
rclone sync \
    --progress \
    "$REPO_ENCRYPTED" "$RCLONE_DESTINATION"

echo "✅ Off-site synchronization complete."

echo "🎉 All backup tasks finished successfully! 🎉"

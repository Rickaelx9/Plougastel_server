#!/bin/bash
set -e  # Exit immediately on error

# --- AJOUT GESTION ERREUR ---
source "$HOME/borg/error_handler.sh"
# ----------------------------

# --- LOAD ENVIRONMENT VARIABLES ---
if [ -f "$HOME/borg/.shares_backup.env" ]; then
    source "$HOME/borg/.shares_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.shares_backup.env"
    exit 1
fi

# --- PATHS & SETTINGS ---
SOURCE_PATH="$SHARES_DATA_PATH"
REPO_ENCRYPTED="$ENCRYPTED_SHARES_BACKUP_PATH"
ARCHIVE_NAME="shares_and_db-{now:%Y-%m-%d_%H-%M-%S}"
PRUNE_ARGS="--keep-daily=7 --keep-weekly=4 --keep-monthly=6"

# Ajout de l'email cible
RECIPIENT_EMAIL="mickael.ramilison@gmail.com"

# --- Function to ensure cleanup happens even if script fails ---
cleanup_and_handle_exit() {
    local exit_code=$? # On capture le code de sortie immédiatement
    set +e # <--- Désactive l'arrêt sur erreur pendant le nettoyage pour garantir l'envoi du mail

    echo "--> Running cleanup..."
    # Always remove the temporary database copy
    rm -f "$DB_BACKUP_FILE"

    if [ "$exit_code" != "0" ]; then
        echo "Script failed. Ensuring container is running..."
        docker compose --project-directory "$FILEBROWSER_PROJECT_PATH" start filebrowser-quantum-public || echo "Could not start container."
    fi
    echo "--> Cleanup complete."

    # On appelle maintenant le gestionnaire d'erreur global (qui s'occupe du mail)
    (exit $exit_code) # Astuce pour restaurer le code d'erreur avant d'appeler handle_exit
    handle_exit
}

# On met en place le nouveau trap combiné
trap cleanup_and_handle_exit EXIT

echo "### Starting Backup Process ###"

# --- INITIALIZE REPOSITORY ---
if [ ! -f "$REPO_ENCRYPTED/config" ]; then
    echo "Initializing ENCRYPTED repository..."
    borg init --encryption=repokey-blake2 "$REPO_ENCRYPTED"
fi

# --- SAFELY COPY THE DATABASE ---
echo "--> Preparing database for backup..."
echo "Stopping FileBrowser container to ensure data consistency..."
docker compose --project-directory "$FILEBROWSER_PROJECT_PATH" stop filebrowser-quantum-public

echo "Copying database file to temporary location..."
cp "$DB_SOURCE_FILE" "$DB_BACKUP_FILE"

echo "Restarting FileBrowser container... (Downtime is over)"
docker compose --project-directory "$FILEBROWSER_PROJECT_PATH" start filebrowser-quantum-public
echo "✅ Database is prepared and service is back online."

# --- CREATE LOCAL BACKUP ---
echo "--> Starting local encrypted backup (Shares + Database)..."

borg create --stats --progress --exclude "$SOURCE_PATH/torrent" "$REPO_ENCRYPTED::$ARCHIVE_NAME" "$SOURCE_PATH" "$DB_BACKUP_FILE"

echo "--> Pruning old backups..."
borg prune $PRUNE_ARGS "$REPO_ENCRYPTED"

echo "✅ Encrypted backup complete."

# --- SYNCHRONIZE OFFSITE BACKUP TO GOOGLE DRIVE ---
echo "--> Synchronizing encrypted repository to Google Drive..."
rclone sync --progress "$REPO_ENCRYPTED" "$RCLONE_SHARES_REMOTE_PATH"
echo "✅ Off-site synchronization complete."

echo "### 🎉 All backup tasks finished successfully! ###"

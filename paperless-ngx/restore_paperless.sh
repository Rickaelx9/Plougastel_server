#!/bin/bash
set -e  # Exit immediately on error

# --- LOAD ENVIRONMENT VARIABLES ---
# We load the same config file used for backup
if [ -f "$HOME/borg/.paperless_backup.env" ]; then
    source "$HOME/borg/.paperless_backup.env"
else
    echo "ERROR: Configuration file not found at $HOME/borg/.paperless_backup.env"
    exit 1
fi

# --- CONFIGURATION ---
REPO_UNENCRYPTED="$UNENCRYPTED_PAPERLESS_BACKUP_PATH"
RESTORE_TARGET_DIR=$(pwd) # Assumes you run the script from /home/pi/paperless-ngx
TEMP_EXTRACT_DIR="$RESTORE_TARGET_DIR/restore_temp"

# Docker Service Name for Database (usually 'db' in docker-compose, checks env if set)
# We need the service name to start it via docker compose, NOT the container name yet.
DB_SERVICE_NAME="db"

echo "#######################################################"
echo "###   PAPERLESS-NGX RESTORE SCRIPT (UNENCRYPTED)    ###"
echo "#######################################################"
echo "Target Directory: $RESTORE_TARGET_DIR"
echo "Borg Repo:        $REPO_UNENCRYPTED"
echo "#######################################################"
echo ""
echo "⚠️  WARNING: This will STOP Paperless, DELETE current 'data'/'media' folders,"
echo "    and OVERWRITE the database with the latest backup."
echo ""
read -p "Are you sure you want to proceed? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Restore cancelled."
    exit 1
fi

# --- STEP 1: PREPARE ENVIRONMENT ---
echo "--> Stopping Paperless containers..."
docker compose down

echo "--> Finding the most recent backup archive..."
# List archives, sort by latest, take the last one, format to show only the name
LATEST_ARCHIVE=$(borg list --sort-by timestamp --last 1 --format "{archive}" "$REPO_UNENCRYPTED")

if [ -z "$LATEST_ARCHIVE" ]; then
    echo "ERROR: No backups found in $REPO_UNENCRYPTED"
    exit 1
fi

echo "✅ Found latest archive: $LATEST_ARCHIVE"

# --- STEP 2: EXTRACT BACKUP ---
echo "--> Extracting backup to temporary directory..."
mkdir -p "$TEMP_EXTRACT_DIR"
cd "$TEMP_EXTRACT_DIR"

# Borg extracts relative to the folder structure stored.
# Since backup used absolute paths, Borg strips the leading '/'.
# Example: stored as "home/pi/paperless-ngx/data"
borg extract --progress "$REPO_UNENCRYPTED::$LATEST_ARCHIVE"

echo "✅ Extraction complete."

# Calculate the path inside the temp folder
# Borg strips the leading slash, so /home/pi becomes home/pi
EXTRACTED_ROOT="$TEMP_EXTRACT_DIR${PAPERLESS_DATA_PATH}"

if [ ! -d "$EXTRACTED_ROOT" ]; then
    echo "ERROR: Extracted path structure does not match expected PAPERLESS_DATA_PATH."
    echo "Expected: $EXTRACTED_ROOT"
    echo "Found contents of temp:"
    ls -R "$TEMP_EXTRACT_DIR"
    exit 1
fi

# --- STEP 3: RESTORE FILES ---
cd "$RESTORE_TARGET_DIR"
echo "--> Restoring File System..."

# 1. Restore DATA
if [ -d "$EXTRACTED_ROOT/data" ]; then
    echo "    Cleaning and restoring 'data'..."
    rm -rf "$RESTORE_TARGET_DIR/data"
    mv "$EXTRACTED_ROOT/data" "$RESTORE_TARGET_DIR/"
else
    echo "⚠️  Warning: 'data' folder not found in backup."
fi

# 2. Restore MEDIA
if [ -d "$EXTRACTED_ROOT/media" ]; then
    echo "    Cleaning and restoring 'media'..."
    rm -rf "$RESTORE_TARGET_DIR/media"
    mv "$EXTRACTED_ROOT/media" "$RESTORE_TARGET_DIR/"
else
    echo "⚠️  Warning: 'media' folder not found in backup."
fi

# --- STEP 4: RESTORE DATABASE ---
echo "--> Restoring Database..."

SQL_DUMP_FILE="$EXTRACTED_ROOT/db_dump/paperless-db.sql"

if [ -f "$SQL_DUMP_FILE" ]; then
    # Start ONLY the database container
    echo "    Starting database container..."
    docker compose up -d "$DB_SERVICE_NAME"

    # Wait a moment for Postgres to initialize
    echo "    Waiting for Database to accept connections..."
    sleep 10

    # We use the container name from your ENV file to target the exec command
    echo "    Importing SQL dump into $PAPERLESS_DB_CONTAINER..."

    # Pass the SQL file into the container's psql command
    # We connect to 'postgres' db initially to allow dropping the paperless db (included in dump)
    cat "$SQL_DUMP_FILE" | docker exec -i "$PAPERLESS_DB_CONTAINER" psql -U "$PAPERLESS_DB_USER" postgres

    echo "✅ Database restore complete."
else
    echo "ERROR: Database dump file not found at $SQL_DUMP_FILE"
    exit 1
fi

# --- STEP 5: CLEANUP AND RESTART ---
echo "--> Cleaning up temporary files..."
rm -rf "$TEMP_EXTRACT_DIR"

echo "--> Restarting full stack..."
docker compose up -d

echo ""
echo "#######################################################"
echo "###      🎉 RESTORE COMPLETED SUCCESSFULLY!         ###"
echo "#######################################################"

#!/bin/bash
set -e

# ==========================================
# 0. CONFIGURATION & ENVIRONMENT
# ==========================================
REAL_USER=${SUDO_USER:-$USER}
USER_HOME="/home/$REAL_USER"
TEMP_RESTORE_BASE="$USER_HOME/tmp_restore"
TEMP_BACKUP_DIR="$USER_HOME/temp_restoration_source"
SERVER_DIR="$USER_HOME/Plougastel_server"
LOCAL_MOUNT_POINT="/mnt/local_backup_drive"

# Borg Silent Mode
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

# ==========================================
# 1. USER PROMPTS & VALIDATION (ALL AT START)
# ==========================================
echo -e "\n\033[1;33m--- ALL-IN-ONE EMERGENCY RESTORE SYSTEM ---\033[0m"

# --- 1. Tailscale ---
echo -e "\n1. Tailscale Setup"
echo "   To get your Tailscale Auth Key, please visit:"
echo "   👉 https://login.tailscale.com/admin/settings/keys"
echo "   Click on 'Generate auth key' to create one."
read -p "   Enter Tailscale Auth Key (tskey-auth-***): " TS_AUTH_KEY

# --- 2. USB Secrets Drive ---
echo -e "\n2. Plug in the USB Stick (Secrets)."
lsblk -o NAME,SIZE,TYPE,MODEL | grep -v "loop"
echo "----------------"
read -p "   Enter USB Partition Name (e.g., sda1): " SECRETS_PARTITION
USB_DEV="/dev/$SECRETS_PARTITION"

# --- 3. USB Password & Immediate Validation ---
echo -n "   Enter USB Encryption Password: "
read -s USB_PASS
echo ""

echo "   🔐 Verifying password..."
if [ ! -e "/dev/mapper/secure_usb" ]; then
    if echo -n "$USB_PASS" | sudo cryptsetup open "$USB_DEV" secure_usb -; then
        echo "   ✅ Password accepted. USB Unlocked."
    else
        echo -e "\n\033[1;31m❌ WRONG PASSWORD or CANNOT OPEN DRIVE. Exiting.\033[0m"
        exit 1
    fi
else
    echo "   (Drive was already unlocked)"
fi

# --- 4. Backup Hard Drive ---
echo -e "\n3. (Optional) Plug in a Backup Hard Drive (HDD/SSD)."
echo "   If skipped, will download from Google Drive."
lsblk -o NAME,SIZE,TYPE,MODEL | grep -v "loop" | grep -v "$SECRETS_PARTITION"
echo "----------------"
read -p "   Enter HDD Partition Name (e.g., sdb1) or [Enter] to skip: " HDD_PART

# ==========================================
# 2. MOUNT SECRETS & LOAD ENV
# ==========================================
echo -e "\n\033[1;34m--- Loading Secrets ---\033[0m"
sudo mkdir -p /mnt/usb
if ! mountpoint -q /mnt/usb; then
    sudo mount /dev/mapper/secure_usb /mnt/usb
fi

if [ -f "/mnt/usb/secrets.env" ]; then
    set -a
    source <(sudo cat /mnt/usb/secrets.env)
    set +a
    echo "✅ Secrets loaded from USB."
else
    echo "❌ secrets.env missing on USB!"
    exit 1
fi

# ==========================================
# 3. INSTALL SYSTEM TOOLS
# ==========================================
echo -e "\n\033[1;34m--- Installing Dependencies ---\033[0m"
sudo apt update && sudo apt install -y git borgbackup rclone cryptsetup

# Install Docker
if command -v docker &> /dev/null; then
    echo "✅ Docker is already installed."
else
    echo "⬇️  Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $REAL_USER
fi

# Install Tailscale
if command -v tailscale &> /dev/null; then
    echo "✅ Tailscale is already installed."
else
    echo "⬇️  Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "--- Authenticating Tailscale ---"
sudo tailscale up --auth-key="$TS_AUTH_KEY"

# ==========================================
# 4. RESTORE CONFIGS
# ==========================================
echo -e "\n\033[1;34m--- Restoring Configurations ---\033[0m"
mkdir -p "$USER_HOME/.ssh" "$USER_HOME/.config/rclone"

safe_copy() {
    if [ -f "$1" ]; then
        sudo cp "$1" "$2"
        sudo chown "$REAL_USER:$REAL_USER" "$2"
        chmod "$3" "$2"
        echo "✅ Restored: $(basename $2)"
    else
        echo "⚠️  Missing: $(basename $1)"
    fi
}

safe_copy "/mnt/usb/id_ed25519"       "$USER_HOME/.ssh/id_ed25519"             600
safe_copy "/mnt/usb/id_ed25519.pub"   "$USER_HOME/.ssh/id_ed25519.pub"         644
safe_copy "/mnt/usb/authorized_keys"  "$USER_HOME/.ssh/authorized_keys"         600
safe_copy "/mnt/usb/rclone.conf"      "$USER_HOME/.config/rclone/rclone.conf"  600

if [ -f "$USER_HOME/.ssh/id_ed25519" ]; then
    ssh-keyscan github.com >> "$USER_HOME/.ssh/known_hosts" 2>/dev/null || true
    sudo chown "$REAL_USER:$REAL_USER" "$USER_HOME/.ssh/known_hosts"
fi

# ==========================================
# 5. CLONE SERVER REPOSITORY
# ==========================================
echo -e "\n\033[1;34m--- Cloning Server Repository ---\033[0m"
sudo rm -rf "$SERVER_DIR"

if sudo -u "$REAL_USER" git clone git@github.com:Rickaelx9/Plougastel_server.git "$SERVER_DIR"; then
    echo "✅ Repository cloned."
else
    echo "❌ Git Clone Failed! Check keys/internet."
    exit 1
fi

# Create .env for Vaultwarden
TS_DOMAIN=$(tailscale status --self --json | grep -o '"DNSName": "[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
TS_IP=$(tailscale ip -4)
echo "VW_DOMAIN=$TS_DOMAIN" > "$SERVER_DIR/vaultwarden/.env"
sudo chown "$REAL_USER:$REAL_USER" "$SERVER_DIR/vaultwarden/.env"

# ==========================================
# 6. RESTORE DATA (HDD or CLOUD)
# ==========================================
echo -e "\n\033[1;35m--- 📥 Data Recovery Strategy ---\033[0m"

USE_LOCAL_HDD=false
if [ -n "$HDD_PART" ]; then
    sudo mkdir -p "$LOCAL_MOUNT_POINT"
    if sudo mount "/dev/$HDD_PART" "$LOCAL_MOUNT_POINT"; then
        echo "✅ HDD mounted at $LOCAL_MOUNT_POINT"
        USE_LOCAL_HDD=true
    else
        echo "⚠️  Failed to mount HDD. Falling back to Cloud."
    fi
fi

# --- Helper Function for finding Repo ---
find_repo() {
    local service_name=$1
    local unencrypted_name="${service_name}_borg_unencrypted"
    local encrypted_name="${service_name}_borg_encrypted"
    local cloud_backup_name="${service_name^}Backup"

    local found_repo=""
    local use_pass=""

    echo -e "\n🔍 Searching for $service_name..."

    if [ "$USE_LOCAL_HDD" = true ]; then
        if [ -d "$LOCAL_MOUNT_POINT/$unencrypted_name" ]; then
            echo "   ✅ Found LOCAL UNENCRYPTED: $unencrypted_name"
            found_repo="$LOCAL_MOUNT_POINT/$unencrypted_name"
            use_pass="no"
        elif [ -d "$LOCAL_MOUNT_POINT/$encrypted_name" ]; then
            echo "   ✅ Found LOCAL ENCRYPTED: $encrypted_name"
            found_repo="$LOCAL_MOUNT_POINT/$encrypted_name"
            use_pass="yes"
        fi
    fi

    if [ -z "$found_repo" ]; then
        echo "   ☁️  Not found locally. Downloading from Google Drive..."
        mkdir -p "$TEMP_BACKUP_DIR"
        REMOTE_NAME=$(sudo -u "$REAL_USER" rclone listremotes | head -n 1 | tr -d :)
        sudo -u "$REAL_USER" rclone sync "$REMOTE_NAME:$cloud_backup_name" "$TEMP_BACKUP_DIR/$cloud_backup_name" --progress
        found_repo="$TEMP_BACKUP_DIR/$cloud_backup_name"
        use_pass="yes"
    fi

    RET_REPO="$found_repo"
    RET_PASS="$use_pass"
}

# --- RESTORE VAULTWARDEN ---
find_repo "vaultwarden"
VW_REPO="$RET_REPO"
VW_NEED_PASS="$RET_PASS"

echo "♻️  Restoring Vaultwarden..."
mkdir -p "$SERVER_DIR/vaultwarden/vw-data"

if [ "$VW_NEED_PASS" == "yes" ]; then
    export BORG_PASSPHRASE="$BORG_PASS_VW"
else
    export BORG_PASSPHRASE=""
fi

if [ -d "$VW_REPO" ]; then
    LATEST_VW=$(borg list "$VW_REPO" --format="{archive}{NEWLINE}" | tail -n 1)
    echo "   Extracting: $LATEST_VW"
    RESTORE_DIR="$TEMP_RESTORE_BASE/restore_vw"
    mkdir -p "$RESTORE_DIR" && cd "$RESTORE_DIR"
    borg extract "$VW_REPO::$LATEST_VW"
    DATA_SRC=$(find . -name "db.sqlite3" -type f -printf '%h\n' | head -n 1)
    if [ -n "$DATA_SRC" ]; then cp -r "$DATA_SRC/." "$SERVER_DIR/vaultwarden/vw-data/"; echo "   ✅ Done."; fi
    rm -rf "$RESTORE_DIR"
fi
# Fix permissions for Vaultwarden container (runs as root UID 0)
sudo chown -R 0:0 "$SERVER_DIR/vaultwarden/vw-data/"
sudo chmod -R 770 "$SERVER_DIR/vaultwarden/vw-data/"
echo "   🔧 Permissions fixed for vw-data."

# --- RESTORE TRILIUM ---
find_repo "trilium"
TR_REPO="$RET_REPO"
TR_NEED_PASS="$RET_PASS"

echo "♻️  Restoring Trilium..."
mkdir -p "$SERVER_DIR/trilium/trilium-data"

if [ "$TR_NEED_PASS" == "yes" ]; then
    export BORG_PASSPHRASE="$BORG_PASS_TR"
else
    export BORG_PASSPHRASE=""
fi

if [ -d "$TR_REPO" ]; then
    LATEST_TR=$(borg list "$TR_REPO" --format="{archive}{NEWLINE}" | tail -n 1)
    echo "   Extracting: $LATEST_TR"
    RESTORE_DIR="$TEMP_RESTORE_BASE/restore_tr"
    mkdir -p "$RESTORE_DIR" && cd "$RESTORE_DIR"
    borg extract "$TR_REPO::$LATEST_TR"
    DATA_SRC=$(find . -name "document.db" -type f -printf '%h\n' | head -n 1)
    if [ -n "$DATA_SRC" ]; then cp -r "$DATA_SRC/." "$SERVER_DIR/trilium/trilium-data/"; echo "   ✅ Done."; fi
    rm -rf "$RESTORE_DIR"
fi

# --- RESTORE PAPERLESS ---
find_repo "paperless"
PL_REPO="$RET_REPO"
PL_NEED_PASS="$RET_PASS"

echo "♻️  Restoring Paperless-ngx..."
mkdir -p "$SERVER_DIR/paperless-ngx"

if [ "$PL_NEED_PASS" == "yes" ]; then
    export BORG_PASSPHRASE="$BORG_PASS_PL"
else
    export BORG_PASSPHRASE=""
fi

if [ -d "$PL_REPO" ]; then
    LATEST_PL=$(borg list "$PL_REPO" --format="{archive}{NEWLINE}" | tail -n 1)
    echo "   Extracting: $LATEST_PL"
    RESTORE_DIR="$TEMP_RESTORE_BASE/restore_pl"
    mkdir -p "$RESTORE_DIR" && cd "$RESTORE_DIR"
    borg extract "$PL_REPO::$LATEST_PL"

    PL_SRC=$(find . -name "db_dump" -type d | head -n 1 | xargs dirname 2>/dev/null)
    if [ -n "$PL_SRC" ]; then
        echo "   Copying Paperless data, media, and db_dump..."
        cp -r "$PL_SRC/data" "$SERVER_DIR/paperless-ngx/" 2>/dev/null || true
        cp -r "$PL_SRC/media" "$SERVER_DIR/paperless-ngx/" 2>/dev/null || true
        cp -r "$PL_SRC/db_dump" "$SERVER_DIR/paperless-ngx/" 2>/dev/null || true
        echo "   ✅ Done."
    fi
    rm -rf "$RESTORE_DIR"
fi

# Fix Paperless permissions (container runs as UID 1000)
echo "   🔧 Fixing Paperless permissions..."
mkdir -p "$SERVER_DIR/paperless-ngx/data/log"
sudo chown -R 1000:1000 "$SERVER_DIR/paperless-ngx/data/"
sudo chown -R 1000:1000 "$SERVER_DIR/paperless-ngx/media/"

sudo chown -R "$REAL_USER:$REAL_USER" "$SERVER_DIR"

# ==========================================
# 7. LAUNCH SERVICES
# ==========================================
echo -e "\n\033[1;32m🚀 Starting Services...\033[0m"

# 1. Vaultwarden
if [ -d "$SERVER_DIR/vaultwarden" ]; then
    echo "   ▶ Starting Vaultwarden..."
    (cd "$SERVER_DIR/vaultwarden" && sudo docker compose up -d)

    echo "   ▶ Configuring Tailscale HTTPS for Vaultwarden..."
    sudo tailscale serve --bg --https=443 localhost:11002
fi

# 2. Trilium
if [ -d "$SERVER_DIR/trilium" ]; then
    echo "   ▶ Starting Trilium..."
    (cd "$SERVER_DIR/trilium" && sudo docker compose up -d)
fi

# 3. Paperless
if [ -d "$SERVER_DIR/paperless-ngx" ]; then
    echo "   ▶ Preparing Paperless-ngx..."

    # Ensure log directory exists with correct permissions
    mkdir -p "$SERVER_DIR/paperless-ngx/data/log"
    sudo chown -R 1000:1000 "$SERVER_DIR/paperless-ngx/data/"
    sudo chown -R 1000:1000 "$SERVER_DIR/paperless-ngx/media/"

    # If we have a DB dump, restore it BEFORE webserver starts
    if [ -f "$SERVER_DIR/paperless-ngx/db_dump/paperless-db.sql" ]; then
        echo "   ▶ Starting ONLY the database container first..."
        (cd "$SERVER_DIR/paperless-ngx" && sudo docker compose up -d db)

        echo "   ▶ Waiting 20s for Postgres to initialize..."
        sleep 20

        # Terminate connections and drop/recreate DB cleanly
        echo "   ▶ Dropping and recreating paperless database..."
        sudo docker exec -i paperless-ngx-db-1 psql -U paperless postgres <<'EOSQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'paperless' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS paperless;
CREATE DATABASE paperless OWNER paperless;
EOSQL

        echo "   ▶ Restoring Paperless Database from SQL dump..."
        sudo docker exec -i paperless-ngx-db-1 psql -U paperless paperless < "$SERVER_DIR/paperless-ngx/db_dump/paperless-db.sql"

        echo "   ✅ Database restored! Now starting all services..."
        (cd "$SERVER_DIR/paperless-ngx" && sudo docker compose up -d)
    else
        echo "   ▶ No DB dump found, starting normally..."
        (cd "$SERVER_DIR/paperless-ngx" && sudo docker compose up -d)
    fi
fi

echo -e "\n\033[1;42m DONE! Critical services are live. \033[0m"

# ==========================================
# 8. CLEANUP
# ==========================================
echo -e "\n\033[1;33m🧹 Cleaning up...\033[0m"
cd "$USER_HOME"
rm -rf "$TEMP_BACKUP_DIR"
rm -rf "$TEMP_RESTORE_BASE"

sync
if [ "$USE_LOCAL_HDD" = true ]; then
    sudo umount "$LOCAL_MOUNT_POINT"
fi

sudo umount -l /mnt/usb
sudo cryptsetup close secure_usb

echo "----------------------------------------------------"
echo "✅ Vaultwarden (HTTPS): https://$TS_DOMAIN"
echo "✅ Trilium (HTTP):      http://$TS_IP:8181"
echo "✅ Paperless (HTTP):    http://$TS_IP:8285"
echo "----------------------------------------------------"

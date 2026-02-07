i#!/bin/bash
set -e

# ==========================================
# 0. CONFIGURATION & ENVIRONMENT
# ==========================================
REAL_USER=${SUDO_USER:-$USER}
USER_HOME="/home/$REAL_USER"

# Borg Silent Mode
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

# ==========================================
# 1. INITIAL SETUP & PROMPTS
# ==========================================
echo -e "\n\033[1;33m--- ALL-IN-ONE EMERGENCY RESTORE SYSTEM ---\033[0m"

# 1. Tailscale Key
echo "1. Enter Tailscale Auth Key:"
read -p "   Key (tskey-auth-***): " TS_AUTH_KEY
echo ""

# 2. USB Detection
echo "2. Plug in USB Key containing secrets.env, id_ed25519, and rclone.conf."
read -p "   Press [Enter] to scan..."

echo -e "\033[1;36m--- Devices ---\033[0m"
lsblk -o NAME,SIZE,TYPE,MODEL | grep -v "loop"
echo "----------------"
read -p "Partition name (e.g., sda1): " PARTITION_NAME
USB_DEV="/dev/$PARTITION_NAME"

# 3. USB Password (Saved for later)
echo "3. Enter USB Encryption Password:"
read -s -p "   Password: " USB_PASS
echo ""
echo "   (Password saved in memory, will be used in Step 3)"

TEMP_BACKUP_DIR="$USER_HOME/temp_restoration_source"
SERVER_DIR="$USER_HOME/Plougastel_server"

# ==========================================
# 2. INSTALL SYSTEM TOOLS
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
# 3. DECRYPT & LOAD SECRETS
# ==========================================
echo -e "\n\033[1;33m🔐 Accessing USB...\033[0m"

# Unlock USB using the saved password
if [ ! -e "/dev/mapper/secure_usb" ]; then
    echo -n "$USB_PASS" | sudo cryptsetup open "$USB_DEV" secure_usb -
    if [ $? -eq 0 ]; then
        echo "✅ USB Unlocked."
    else
        echo "❌ Password incorrect or USB error."
        exit 1
    fi
fi
unset USB_PASS 

sudo mkdir -p /mnt/usb
if ! mountpoint -q /mnt/usb; then
    sudo mount /dev/mapper/secure_usb /mnt/usb
fi

if [ -f "/mnt/usb/secrets.env" ]; then
    set -a
    source <(sudo cat /mnt/usb/secrets.env)
    set +a
    echo "✅ Secrets loaded."
else
    echo "❌ secrets.env missing on USB!"
    exit 1
fi

# ==========================================
# 4. RESTORE CONFIGS
# ==========================================
echo -e "\n\033[1;34m--- Restoring Configurations ---\033[0m"
mkdir -p "$USER_HOME/.ssh" "$USER_HOME/.config/rclone"

safe_copy() {
    local src="$1"
    local dest="$2"
    local perms="$3"
    if [ -f "$src" ]; then
        sudo cp "$src" "$dest"
        sudo chown "$REAL_USER:$REAL_USER" "$dest"
        chmod "$perms" "$dest"
        echo "✅ Restored: $(basename $dest)"
    else
        echo "⚠️  Missing: $(basename $src)"
    fi
}

safe_copy "/mnt/usb/id_ed25519"     "$USER_HOME/.ssh/id_ed25519"     600
safe_copy "/mnt/usb/id_ed25519.pub" "$USER_HOME/.ssh/id_ed25519.pub" 644
safe_copy "/mnt/usb/authorized_keys" "$USER_HOME/.ssh/authorized_keys" 600
safe_copy "/mnt/usb/rclone.conf"    "$USER_HOME/.config/rclone/rclone.conf" 600

if [ -f "$USER_HOME/.ssh/id_ed25519" ]; then
    ssh-keyscan github.com >> "$USER_HOME/.ssh/known_hosts" 2>/dev/null || true
    sudo chown "$REAL_USER:$REAL_USER" "$USER_HOME/.ssh/known_hosts"
fi

# ==========================================
# 5. CLONE SERVER REPOSITORY
# ==========================================
echo -e "\n\033[1;34m--- Cloning Server Repository ---\033[0m"
rm -rf "$SERVER_DIR"

if sudo -u "$REAL_USER" git clone git@github.com:Rickaelx9/Plougastel_server.git "$SERVER_DIR"; then
    echo "✅ Repository cloned."
else
    echo "❌ Git Clone Failed! Check keys/internet."
    exit 1
fi

# Get Tailscale Info
TS_DOMAIN=$(tailscale status --self --json | grep -o '"DNSName": "[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
TS_IP=$(tailscale ip -4)

# Create .env for Vaultwarden
echo "VW_DOMAIN=$TS_DOMAIN" > "$SERVER_DIR/vaultwarden/.env"
sudo chown "$REAL_USER:$REAL_USER" "$SERVER_DIR/vaultwarden/.env"

# ==========================================
# 6. RESTORE DATA
# ==========================================
echo -e "\n\033[1;35m--- 📥 Downloading Backups ---\033[0m"
mkdir -p "$TEMP_BACKUP_DIR"
sudo chown "$REAL_USER:$REAL_USER" "$TEMP_BACKUP_DIR"

REMOTE_NAME=$(sudo -u "$REAL_USER" rclone listremotes | head -n 1 | tr -d :)
if [ -z "$REMOTE_NAME" ]; then echo "❌ No Rclone remote found!"; exit 1; fi

sudo -u "$REAL_USER" rclone sync "$REMOTE_NAME:VaultwardenBackup" "$TEMP_BACKUP_DIR/VaultwardenBackup" --progress
sudo -u "$REAL_USER" rclone sync "$REMOTE_NAME:TriliumBackup" "$TEMP_BACKUP_DIR/TriliumBackup" --progress

# --- Restore Vaultwarden ---
echo -e "\n\033[1;36m♻️  Restoring Vaultwarden...\033[0m"
export BORG_PASSPHRASE="$BORG_PASS_VW"
VW_REPO="$TEMP_BACKUP_DIR/VaultwardenBackup"
mkdir -p "$SERVER_DIR/vaultwarden/vw-data"

if [ -d "$VW_REPO" ]; then
    LATEST_VW=$(borg list "$VW_REPO" --format="{archive}{NEWLINE}" | tail -n 1)
    echo "Extracting: $LATEST_VW"
    mkdir -p /tmp/restore_vw && cd /tmp/restore_vw
    borg extract "$VW_REPO::$LATEST_VW"
    DATA_SRC=$(find . -name "db.sqlite3" -type f -printf '%h\n' | head -n 1)
    if [ -n "$DATA_SRC" ]; then cp -r "$DATA_SRC/." "$SERVER_DIR/vaultwarden/vw-data/"; echo "✅ Done."; fi
    rm -rf /tmp/restore_vw
fi

# --- Restore Trilium ---
echo -e "\n\033[1;36m♻️  Restoring Trilium...\033[0m"
export BORG_PASSPHRASE="$BORG_PASS_TR"
TR_REPO="$TEMP_BACKUP_DIR/TriliumBackup"
mkdir -p "$SERVER_DIR/trilium/trilium-data"

if [ -d "$TR_REPO" ]; then
    LATEST_TR=$(borg list "$TR_REPO" --format="{archive}{NEWLINE}" | tail -n 1)
    echo "Extracting: $LATEST_TR"
    mkdir -p /tmp/restore_tr && cd /tmp/restore_tr
    borg extract "$TR_REPO::$LATEST_TR"
    DATA_SRC=$(find . -name "document.db" -type f -printf '%h\n' | head -n 1)
    if [ -n "$DATA_SRC" ]; then cp -r "$DATA_SRC/." "$SERVER_DIR/trilium/trilium-data/"; echo "✅ Done."; fi
    rm -rf /tmp/restore_tr
fi

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
    # Map external HTTPS (443) to internal Docker port (11001)
    sudo tailscale serve --bg --https=443 localhost:11001
else
    echo "⚠️  Vaultwarden folder not found."
fi

# 2. Trilium
if [ -d "$SERVER_DIR/trilium" ]; then
    echo "   ▶ Starting Trilium..."
    (cd "$SERVER_DIR/trilium" && sudo docker compose up -d)
else
    echo "⚠️  Trilium folder not found."
fi

echo -e "\n\033[1;42m DONE! Critical services are live. \033[0m"

# ==========================================
# 8. CLEANUP
# ==========================================
echo -e "\n\033[1;33m🧹 Cleaning up...\033[0m"
cd "$USER_HOME"
rm -rf "$TEMP_BACKUP_DIR"

sync
sudo umount -l /mnt/usb
sudo cryptsetup close secure_usb

echo "----------------------------------------------------"
echo "✅ Vaultwarden (HTTPS): https://$TS_DOMAIN"
echo "✅ Trilium (HTTP):      http://$TS_IP:8181"
echo "----------------------------------------------------"



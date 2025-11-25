#!/bin/bash

# --- CONFIGURATION ---
# URL locale (dans le docker, localhost:9091 fonctionne car le script tourne dedans)
QBIT_URL="http://localhost:9091"
USER="admin"
PASS="Jessie-Pinkman92"  # Remplace par ton mot de passe WebUI

# Hash du torrent passé en argument par qBittorrent
TORRENT_HASH=$1

# Fichier temporaire pour les cookies
COOKIE_FILE="/tmp/qbit_cookie.txt"

# --- FONCTIONS ---

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /config/automation.log
}

# 1. Authentification
auth() {
    curl -s -i --header "Referer: $QBIT_URL" --data "username=$USER&password=$PASS" -c "$COOKIE_FILE" "$QBIT_URL/api/v2/auth/login" > /dev/null
}

# 2. Activer la vitesse alternative (Mode 1 = Actif)
enable_alt_speed() {
    log "Activation vitesse alternative..."
    curl -s -b "$COOKIE_FILE" -d "mode=1" "$QBIT_URL/api/v2/transfer/toggleSpeedLimitsMode"
}

# 3. Désactiver la vitesse alternative (Mode 0 = Inactif)
disable_alt_speed() {
    log "Désactivation vitesse alternative..."
    curl -s -b "$COOKIE_FILE" -d "mode=0" "$QBIT_URL/api/v2/transfer/toggleSpeedLimitsMode"
}

# 4. Supprimer tous les trackers
remove_trackers() {
    log "Récupération des trackers pour $TORRENT_HASH..."

    # Récupère la liste des URLs des trackers via l'API et les joint avec le séparateur "|" (requis par l'API)
    TRACKERS_LIST=$(curl -s -b "$COOKIE_FILE" "$QBIT_URL/api/v2/torrents/trackers?hash=$TORRENT_HASH" | jq -r '.[].url' | paste -sd "|" -)

    if [ -z "$TRACKERS_LIST" ]; then
        log "Aucun tracker trouvé ou erreur."
    else
        log "Suppression des trackers..."
        # Encodage URL nécessaire pour les caractères spéciaux dans les trackers
        curl -s -b "$COOKIE_FILE" --data-urlencode "hash=$TORRENT_HASH" --data-urlencode "urls=$TRACKERS_LIST" "$QBIT_URL/api/v2/torrents/removeTrackers"
    fi
}

# --- EXECUTION ---

# Si pas de hash, on quitte
if [ -z "$TORRENT_HASH" ]; then
    echo "Erreur: Pas de hash fourni."
    exit 1
fi

# Authentification
auth

# Active la limite
enable_alt_speed

# Pause de 10 secondes
log "Pause de 10 secondes..."
sleep 10

# Supprime les trackers
remove_trackers

# Pause de 10 secondes
log "Pause de 10 secondes..."
sleep 10

# Remet la vitesse normale
disable_alt_speed

log "Terminé pour $TORRENT_HASH."

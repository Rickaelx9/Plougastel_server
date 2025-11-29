#!/bin/bash

# Répertoire de base où sont situés tous vos dossiers de services.
# Ceci suppose que le script est dans /home/pi/scripts et que les dossiers des services sont directement sous /home/pi/.
BASE_DIR="/home/pi" 

# Liste des répertoires de services à mettre à jour.
# Assurez-vous que cette liste correspond aux noms de vos dossiers de services.
SERVICE_DIRS=(
  "actual"
  "glances"
  "homebase" # Incluez homepage si vous voulez qu'il se mette à jour lui-même
  "immich"
  "jellyfin"
  "komga"
  "paperless-ngx"
  "proxy"
  "qbittorrent"
  "trilium"
  "vaultwarden"
  "webdav_file_browser"
)

echo "Démarrage de la mise à jour de tous les services Docker Compose..."

for dir in "${SERVICE_DIRS[@]}"; do
  SERVICE_PATH="${BASE_DIR}/${dir}"
  if [ -f "${SERVICE_PATH}/docker-compose.yml" ]; then
    echo "----------------------------------------------------"
    echo "Mise à jour du service dans ${SERVICE_PATH}..."
    cd "${SERVICE_PATH}" || { echo "Erreur: Impossible de naviguer vers ${SERVICE_PATH}"; continue; }
    
    # Vérifie si la commande 'docker compose' (plugin) ou 'docker-compose' (legacy) est disponible
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
      echo "Utilisation de 'docker compose' (plugin)..."
      docker compose pull && docker compose up -d
    elif command -v docker-compose &> /dev/null; then
      echo "Utilisation de 'docker-compose' (commande legacy)..."
      docker-compose pull && docker-compose up -d
    else
      echo "Erreur: Les commandes 'docker compose' ou 'docker-compose' sont introuvables."
    fi
    
    if [ $? -eq 0 ]; then
      echo "Service dans ${SERVICE_PATH} mis à jour avec succès."
    else
      echo "Échec de la mise à jour du service dans ${SERVICE_PATH}."
    fi
    cd - > /dev/null # Retourne au répertoire précédent
  else
    echo "----------------------------------------------------"
    echo "Attention: 'docker-compose.yml' non trouvé dans ${SERVICE_PATH}, ignoré."
  fi
done

echo "----------------------------------------------------"
echo "Processus de mise à jour de tous les services terminé."


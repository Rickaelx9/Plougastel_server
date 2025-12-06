#!/bin/bash

# Configuration de l'email de réception
# Vous pouvez aussi mettre cette variable dans vos fichiers .env
RECIPIENT_EMAIL="mickael.ramilison@gmail.com"

handle_exit() {
    local exit_code=$?
    local script_name="$0"

    # Si le code de sortie n'est pas 0, c'est une erreur
    if [ $exit_code -ne 0 ]; then
        echo "❌ Le script $script_name a échoué (Code: $exit_code)."

        # Préparation du corps du mail
        # On inclut les dernières lignes du log si disponible, ou un message générique
        BODY="Le script de backup '$script_name' sur la Raspberry Pi a échoué.\n\nCode d'erreur : $exit_code\nDate : $(date)"

        # Envoi du mail
        echo -e "$BODY" | mail -s "🚨 ÉCHEC BACKUP : $(basename "$script_name")" "$RECIPIENT_EMAIL"

        echo "📧 Notification d'erreur envoyée à $RECIPIENT_EMAIL"
    fi
}

# On active le piège (trap) sur la sortie du script
trap handle_exit EXIT

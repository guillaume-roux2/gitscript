#!/bin/bash
#
# dialog_script.sh
# Crée un dépôt GitHub avec un sous-dossier par job, puis invite les collaborateurs. Interface : dialog.


CONFIG_DIR="$HOME/.config/gitscript"
CONFIG_FILE="$CONFIG_DIR/config"
TITRE="Création de dépôt GitHub"


#Fonctions utilitaires pour dialog

#Quitte proprement si l'utilisateur annule
annuler() {
    clear
    echo "Opération annulée."
    exit 0
}

#Affiche une erreur dans une boîte, puis quitte
erreur() {
    dialog --backtitle "$TITRE" --title "Erreur" --msgbox "$1" 0 0
    clear
    echo "Erreur : $1" >&2
    exit 1
}

#Affiche un message avec un bouton OK
message() {
    dialog --backtitle "$TITRE" --title "$1" --msgbox "$2" 0 0
}

#Affiche un message de progression (sans bouton)
info() {
    dialog --backtitle "$TITRE" --infobox "$1" 5 60
}

#Pose une question et range la réponse dans la variable nommée en $1
#Exemple : saisir REPO --inputbox "Nom du dépôt :" 8 60
saisir() {
    local __var=$1
    shift
    local __rep
    __rep=$(dialog --backtitle "$TITRE" "$@" 3>&1 1>&2 2>&3) || annuler
    printf -v "$__var" '%s' "$__rep"
}


#Étape 1 : vérification et installation des outils
verifier_outils() {
    sudo apt update

    local paquet
    for paquet in git jq curl dialog; do
        if command -v "$paquet" > /dev/null; then
            echo "$paquet est installé sur cette machine"
        else
            echo "$paquet n'est pas installé sur cette machine"
            sudo apt install -y "$paquet"
        fi
    done
}


#Étape 2 : chargement du jeton et vérification du compte
charger_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        #insecure affiche des * pendant la saisie (le jeton reste masqué)
        saisir TOKEN --insecure --title "Premier lancement" \
            --passwordbox "Entrez votre jeton GitHub :" 8 60

        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
        touch "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo "TOKEN=\"$TOKEN\"" > "$CONFIG_FILE"
    fi

    info "Vérification du jeton auprès de GitHub..."
    REPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" https://api.github.com/user)
    UTILISATEUR=$(echo "$REPONSE" | jq -r '.login')

    if [ -z "$UTILISATEUR" ] || [ "$UTILISATEUR" = "null" ]; then
        rm -f "$CONFIG_FILE"
        erreur "Jeton invalide ou expiré.\nRelancez le script pour en saisir un nouveau."
    fi
}


#Étape 3 : saisie des informations du projet
saisir_informations() {
    local CODE collab COLLABS_TEXTE SAISIE INCONNUS

    #Nom du dépôt
    while true; do
        saisir REPO --title "Connecté en tant que $UTILISATEUR" \
            --inputbox "Nom du dépôt :" 8 60
        if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
            message "Nom invalide" "Lettres, chiffres, '.', '_' et '-' uniquement."
        elif [ -e "$REPO" ]; then
            message "Nom déjà pris" "Un dossier '$REPO' existe déjà ici."
        else
            info "Vérification du nom sur GitHub..."
            CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer $TOKEN" \
                "https://api.github.com/repos/$UTILISATEUR/$REPO")
            if [ "$CODE" = "200" ]; then
                message "Nom déjà pris" "Le dépôt '$REPO' existe déjà sur votre compte GitHub."
            else
                break
            fi
        fi
    done

    #Visibilité : Oui = privé, Non = public, Échap = annuler
    dialog --backtitle "$TITRE" --title "Visibilité" --defaultno \
        --yesno "Le dépôt doit-il être privé ?" 7 50
    case $? in
        0) PRIVE=true ;;
        1) PRIVE=false ;;
        *) annuler ;;
    esac

    #Nombre de jobs
    while true; do
        saisir NB_JOBS --title "Jobs" --inputbox "Nombre de jobs (1 à 99) :" 8 60
        if [[ "$NB_JOBS" =~ ^[1-9][0-9]?$ ]]; then
            break
        else
            message "Valeur invalide" "Veuillez entrer un nombre entier entre 1 et 99."
        fi
    done

    #Collaborateurs
    saisir COLLABS_TEXTE --title "Collaborateurs" \
        --inputbox "Pseudos GitHub séparés par des espaces\n(laisser vide pour aucun) :" 9 60
    read -r -a SAISIE <<< "$COLLABS_TEXTE"

    COLLABORATEURS=()
    INCONNUS=""
    if [ ${#SAISIE[@]} -gt 0 ]; then
        info "Vérification des collaborateurs..."
    fi
    for collab in "${SAISIE[@]}"; do
        if [ "$collab" = "$UTILISATEUR" ]; then
            continue
        fi
        CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer $TOKEN" \
            "https://api.github.com/users/$collab")
        if [ "$CODE" = "200" ]; then
            COLLABORATEURS+=("$collab")
        else
            INCONNUS+="  - $collab\n"
        fi
    done

    if [ -n "$INCONNUS" ]; then
        message "Collaborateurs ignorés" "Introuvables sur GitHub :\n$INCONNUS"
    fi

    #Récapitulatif et confirmation
    dialog --backtitle "$TITRE" --title "Récapitulatif" --defaultno \
        --yesno "Dépôt          : $UTILISATEUR/$REPO\nPrivé          : $PRIVE\nJobs           : $NB_JOBS\nCollaborateurs : ${COLLABORATEURS[*]:-aucun}\n\nConfirmer la création ?" 13 70 \
        || annuler
}


#Étapes 4 et 5 : dossiers locaux et premier commit
creer_depot_local() {
    local i DOSSIER ID

    info "Création des dossiers et du premier commit..."

    mkdir "$REPO" || erreur "Impossible de créer le dossier '$REPO'."
    cd "$REPO" || erreur "Impossible d'entrer dans le dossier '$REPO'."

    for ((i = 1; i <= NB_JOBS; i++)); do
        printf -v DOSSIER "job%02d" "$i"
        mkdir "$DOSSIER"
        touch "$DOSSIER/.gitkeep"
    done

    echo "# $REPO" > README.md

    git init -b main > /dev/null 2>&1

    if [ -z "$(git config user.name)" ]; then
        git config user.name "$UTILISATEUR"
    fi
    if [ -z "$(git config user.email)" ]; then
        ID=$(echo "$REPONSE" | jq -r '.id')
        git config user.email "$ID+$UTILISATEUR@users.noreply.github.com"
    fi

    git add .
    git commit -m "Initialisation du projet avec $NB_JOBS jobs" > /dev/null 2>&1 \
        || erreur "Le premier commit a échoué."
}


#Étape 6 : création du dépôt sur GitHub et envoi
creer_depot_github() {
    local DONNEES CREATION URL AUTH

    info "Création du dépôt sur GitHub..."

    DONNEES=$(jq -n --arg name "$REPO" --argjson private "$PRIVE" \
        '{name: $name, private: $private}')

    CREATION=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -d "$DONNEES" \
        https://api.github.com/user/repos)

    URL=$(echo "$CREATION" | jq -r '.clone_url')

    if [ -z "$URL" ] || [ "$URL" = "null" ]; then
        erreur "Création du dépôt refusée par GitHub :\n$(echo "$CREATION" | jq -r '.message')"
    fi

    git remote add origin "$URL"

    info "Envoi des fichiers sur GitHub..."
    AUTH=$(printf '%s' "$UTILISATEUR:$TOKEN" | base64 -w0)
    git -c http.extraHeader="Authorization: Basic $AUTH" push -u origin main > /dev/null 2>&1 \
        || erreur "Le dépôt a été créé mais l'envoi des fichiers a échoué."
}


#Étape 7 : invitation des collaborateurs
inviter_collaborateurs() {
    local collab CODE

    RESULTATS=""
    if [ ${#COLLABORATEURS[@]} -eq 0 ]; then
        return
    fi

    info "Envoi des invitations..."
    for collab in "${COLLABORATEURS[@]}"; do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -d '{"permission": "push"}' \
            "https://api.github.com/repos/$UTILISATEUR/$REPO/collaborators/$collab")

        case "$CODE" in
            201) RESULTATS+="  - $collab : invitation envoyée\n" ;;
            204) RESULTATS+="  - $collab : déjà collaborateur\n" ;;
            *)   RESULTATS+="  - $collab : échec (code $CODE)\n" ;;
        esac
    done
}


#Programme principal
main() {
    verifier_outils
    charger_config
    saisir_informations
    creer_depot_local
    creer_depot_github
    inviter_collaborateurs

    message "Projet prêt" "Dépôt : https://github.com/$UTILISATEUR/$REPO\nJobs créés : $NB_JOBS\n\nCollaborateurs :\n${RESULTATS:-  aucun}"
    clear
    echo "Projet prêt : https://github.com/$UTILISATEUR/$REPO"
}

main

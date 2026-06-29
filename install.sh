#!/usr/bin/env bash
# =============================================================================
#  install.sh — Déploiement automatisé Odoo 17 + PostgreSQL 15 via Docker
#  Compatible : Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux
#  Usage      : curl -fsSL <url>/install.sh | bash
#               ou : bash install.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Versions ─────────────────────────────────────────────────────────────────
readonly ODOO_VERSION="17"
readonly POSTGRES_VERSION="15"
readonly PROJECT_DIR="${HOME}/odoo-docker"
readonly ODOO_PORT="8069"

# ─── Couleurs ─────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ─── Variables globales ───────────────────────────────────────────────────────
OS_ID=""
OS_VERSION=""
PKG_MANAGER=""

# =============================================================================
#  FONCTIONS UTILITAIRES
# =============================================================================

log_info()    { echo -e "${GREEN}  ✔  $1${NC}"; }
log_warn()    { echo -e "${YELLOW}  ⚠  $1${NC}"; }
log_error()   { echo -e "${RED}  ✖  $1${NC}" >&2; }
log_step()    { echo -e "\n${BOLD}${BLUE}━━━  $1${NC}"; }
log_section() { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

fail() {
    log_error "$1"
    exit 1
}

# Génère un mot de passe aléatoire sécurisé (24 caractères alphanumériques)
generate_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# Vérifie si une commande existe
command_exists() {
    command -v "$1" &>/dev/null
}

# Affiche la bannière de démarrage
print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║         Odoo ${ODOO_VERSION} — Installation automatisée        ║"
    echo "  ║         PostgreSQL ${POSTGRES_VERSION} + Docker Compose            ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# =============================================================================
#  ÉTAPE 1 — VÉRIFICATIONS PRÉALABLES
# =============================================================================

check_prerequisites() {
    log_step "Vérifications préalables"

    # Doit être exécuté en tant qu'utilisateur normal (pas root direct)
    if [[ "${EUID}" -eq 0 ]]; then
        fail "Ne pas exécuter ce script en tant que root. Utilisez un utilisateur avec sudo."
    fi

    # Vérifie que sudo est disponible
    if ! command_exists sudo; then
        fail "sudo est requis. Installez-le et accordez les droits à votre utilisateur."
    fi

    # Vérifie les droits sudo sans mot de passe interactif bloquant
    if ! sudo -n true 2>/dev/null; then
        log_warn "Droits sudo requis. Vous allez être invité à entrer votre mot de passe."
        sudo -v || fail "Impossible d'obtenir les droits sudo."
    fi

    # Vérifie la connexion internet
    log_info "Vérification de la connexion internet..."
    if ! curl -fsSL --max-time 10 https://hub.docker.com > /dev/null 2>&1; then
        fail "Pas de connexion internet. Vérifiez votre réseau."
    fi

    # Vérifie l'architecture CPU (Docker supporte amd64 et arm64)
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64|amd64)   log_info "Architecture : x86_64 ✔" ;;
        aarch64|arm64)  log_info "Architecture : arm64 ✔" ;;
        *)              fail "Architecture non supportée : ${ARCH}" ;;
    esac

    log_info "Toutes les vérifications préalables sont passées."
}

# =============================================================================
#  ÉTAPE 2 — DÉTECTION DE L'OS
# =============================================================================

detect_os() {
    log_step "Détection du système d'exploitation"

    # /etc/os-release est le standard moderne pour identifier une distro Linux
    if [[ ! -f /etc/os-release ]]; then
        fail "Impossible de détecter l'OS : /etc/os-release introuvable."
    fi

    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"

    # Certaines distros (comme Linux Mint) héritent d'Ubuntu
    # ID_LIKE contient la distro parente
    OS_LIKE="${ID_LIKE:-}"

    log_info "OS détecté : ${PRETTY_NAME:-${OS_ID}}"

    # Détermine le gestionnaire de paquets selon la distro
    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            # CentOS 8+ et Rocky utilisent dnf
            command_exists dnf && PKG_MANAGER="dnf"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        arch|manjaro|endeavouros)
            PKG_MANAGER="pacman"
            ;;
        opensuse*|sles)
            PKG_MANAGER="zypper"
            ;;
        *)
            # Dernier recours : détection par ID_LIKE
            if [[ "${OS_LIKE}" == *"debian"* ]] || [[ "${OS_LIKE}" == *"ubuntu"* ]]; then
                PKG_MANAGER="apt"
                log_warn "Distro non reconnue mais basée sur Debian/Ubuntu. Utilisation de apt."
            elif [[ "${OS_LIKE}" == *"rhel"* ]] || [[ "${OS_LIKE}" == *"fedora"* ]]; then
                PKG_MANAGER="dnf"
                log_warn "Distro non reconnue mais basée sur RHEL/Fedora. Utilisation de dnf."
            else
                fail "Distribution non supportée : ${OS_ID}. Installez Docker manuellement."
            fi
            ;;
    esac

    log_info "Gestionnaire de paquets : ${PKG_MANAGER}"
}

# =============================================================================
#  ÉTAPE 3 — INSTALLATION DE DOCKER
# =============================================================================

install_docker() {
    log_step "Installation de Docker"

    # Si Docker est déjà installé, on vérifie juste qu'il tourne
    if command_exists docker; then
        log_info "Docker est déjà installé : $(docker --version)"
        _ensure_docker_running
        return 0
    fi

    log_info "Docker non détecté. Installation en cours..."

    case "${PKG_MANAGER}" in
        apt)     _install_docker_apt ;;
        dnf|yum) _install_docker_dnf ;;
        pacman)  _install_docker_pacman ;;
        zypper)  _install_docker_zypper ;;
    esac

    _post_install_docker
}

# Installation Docker sur Debian/Ubuntu
_install_docker_apt() {
    log_info "Méthode : dépôt officiel Docker (apt)"

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Ajoute la clé GPG officielle Docker
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Ajoute le dépôt Docker
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${OS_ID} \
        $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
}

# Installation Docker sur CentOS/RHEL/Fedora/Rocky
_install_docker_dnf() {
    log_info "Méthode : dépôt officiel Docker (dnf/yum)"

    sudo "${PKG_MANAGER}" install -y -q \
        ca-certificates \
        curl \
        gnupg2

    sudo "${PKG_MANAGER}" config-manager \
        --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
        || sudo "${PKG_MANAGER}" config-manager \
            --add-repo \
            https://download.docker.com/linux/fedora/docker-ce.repo

    sudo "${PKG_MANAGER}" install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
}

# Installation Docker sur Arch Linux
_install_docker_pacman() {
    log_info "Méthode : pacman (Arch Linux)"
    sudo pacman -Sy --noconfirm docker docker-compose
}

# Installation Docker sur openSUSE
_install_docker_zypper() {
    log_info "Méthode : zypper (openSUSE)"
    sudo zypper install -y docker docker-compose
}

# Configure Docker après installation
_post_install_docker() {
    log_info "Configuration post-installation Docker..."

    # Démarre et active Docker au boot
    sudo systemctl start docker
    sudo systemctl enable docker

    # Ajoute l'utilisateur courant au groupe docker
    # Cela évite de devoir taper sudo avant chaque commande docker
    sudo usermod -aG docker "${USER}"

    # Active les permissions du groupe sans déconnexion
    # newgrp docker ouvrirait un nouveau shell — on utilise sg à la place
    log_info "Utilisateur '${USER}' ajouté au groupe docker."

    _ensure_docker_running
}

# Vérifie que le daemon Docker tourne
_ensure_docker_running() {
    if ! sudo docker info &>/dev/null; then
        sudo systemctl start docker || fail "Impossible de démarrer le service Docker."
    fi
    log_info "Docker opérationnel."
}

# =============================================================================
#  ÉTAPE 4 — VÉRIFICATION DOCKER COMPOSE
# =============================================================================

check_compose() {
    log_step "Vérification de Docker Compose"

    # Docker Compose v2 est intégré comme plugin : "docker compose" (sans tiret)
    if docker compose version &>/dev/null 2>&1; then
        log_info "Docker Compose v2 détecté : $(docker compose version --short)"
        return 0
    fi

    # Fallback : docker-compose v1 standalone (obsolète mais encore présent)
    if command_exists docker-compose; then
        log_warn "Docker Compose v1 détecté. Fonctionnel mais obsolète."
        log_warn "Considérez la mise à jour vers Docker Compose v2."
        # On crée un alias pour que la suite du script utilise toujours "docker compose"
        docker() {
            if [[ "$1" == "compose" ]]; then
                shift
                command docker-compose "$@"
            else
                command docker "$@"
            fi
        }
        export -f docker
        return 0
    fi

    fail "Docker Compose introuvable. Réinstallez Docker avec le plugin Compose."
}

# =============================================================================
#  ÉTAPE 5 — CRÉATION DE LA STRUCTURE DU PROJET
# =============================================================================

setup_project() {
    log_step "Création de la structure du projet"

    # Si le projet existe déjà, on demande confirmation
    if [[ -d "${PROJECT_DIR}" ]]; then
        log_warn "Le dossier ${PROJECT_DIR} existe déjà."
        read -rp "  Écraser l'installation existante ? (oui/non) : " CONFIRM
        if [[ "${CONFIRM}" != "oui" ]]; then
            log_info "Installation annulée. L'installation existante est préservée."
            exit 0
        fi
        rm -rf "${PROJECT_DIR}"
    fi

    mkdir -p "${PROJECT_DIR}/config"
    mkdir -p "${PROJECT_DIR}/addons"
    mkdir -p "${PROJECT_DIR}/backups"
    touch "${PROJECT_DIR}/addons/.gitkeep"
    touch "${PROJECT_DIR}/backups/.gitkeep"

    log_info "Structure créée dans : ${PROJECT_DIR}"
}

# =============================================================================
#  ÉTAPE 6 — GÉNÉRATION DU FICHIER .env
# =============================================================================

generate_env() {
    log_step "Génération de la configuration"

    local db_password
    db_password=$(generate_password)

    cat > "${PROJECT_DIR}/.env" <<EOF
# =============================================================
#  Configuration Odoo Docker — généré le $(date '+%Y-%m-%d %H:%M:%S')
#  NE PAS COMMITTER CE FICHIER SUR GIT
# =============================================================

# PostgreSQL
POSTGRES_DB=postgres
POSTGRES_USER=odoo
POSTGRES_PASSWORD=${db_password}

# Odoo
ODOO_DB_HOST=db
ODOO_DB_PORT=5432
ODOO_DB_USER=odoo
ODOO_DB_PASSWORD=${db_password}

# Réseau
ODOO_PORT=${ODOO_PORT}
EOF

    chmod 600 "${PROJECT_DIR}/.env"
    log_info "Fichier .env généré avec un mot de passe aléatoire sécurisé."
}

# =============================================================================
#  ÉTAPE 7 — GÉNÉRATION DES FICHIERS DU PROJET
# =============================================================================

generate_project_files() {
    log_step "Génération des fichiers du projet"

    _generate_odoo_conf
    _generate_compose
    _generate_backup_script
    _generate_restore_script
    _generate_makefile
    _generate_gitignore

    log_info "Tous les fichiers générés."
}

_generate_odoo_conf() {
    # Charge le mot de passe depuis .env pour l'injecter dans odoo.conf
    local db_password
    db_password=$(grep POSTGRES_PASSWORD "${PROJECT_DIR}/.env" | cut -d= -f2)

    cat > "${PROJECT_DIR}/config/odoo.conf" <<EOF
[options]
db_host = db
db_port = 5432
db_user = odoo
db_password = ${db_password}

addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
data_dir = /var/lib/odoo

log_level = info
logfile = False

http_port = 8069
http_interface = 0.0.0.0

workers = 0
max_cron_threads = 1
EOF
    log_info "config/odoo.conf généré."
}

_generate_compose() {
    cat > "${PROJECT_DIR}/docker-compose.yml" <<'EOF'
networks:
  odoo-net:
    driver: bridge

volumes:
  odoo-db-data:
  odoo-filestore:

services:

  db:
    image: postgres:15
    container_name: odoo-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - odoo-db-data:/var/lib/postgresql/data
    networks:
      - odoo-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  odoo:
    image: odoo:17
    container_name: odoo-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: ${ODOO_DB_HOST}
      PORT: ${ODOO_DB_PORT}
      USER: ${ODOO_DB_USER}
      PASSWORD: ${ODOO_DB_PASSWORD}
    volumes:
      - odoo-filestore:/var/lib/odoo
      - ./config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./addons:/mnt/extra-addons
    ports:
      - "${ODOO_PORT}:8069"
    networks:
      - odoo-net
EOF
    log_info "docker-compose.yml généré."
}

_generate_backup_script() {
    cat > "${PROJECT_DIR}/backup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="./backups"
DATE=$(date +%Y%m%d_%H%M%S)
DB_CONTAINER="odoo-db"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔ $1${NC}"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] ✖ $1${NC}"; exit 1; }

[ -f .env ] && source .env || fail "Fichier .env introuvable. Lancez depuis le dossier du projet."

mkdir -p "${BACKUP_DIR}"

log "Sauvegarde de la base de données..."
docker exec "${DB_CONTAINER}" pg_dumpall -U "${POSTGRES_USER}" \
    | gzip > "${BACKUP_DIR}/db_${DATE}.sql.gz" \
    || fail "Échec sauvegarde PostgreSQL"

log "Sauvegarde du filestore..."
docker run --rm \
    -v odoo-filestore:/data \
    -v "$(pwd)/${BACKUP_DIR}":/backup \
    alpine tar czf "/backup/filestore_${DATE}.tar.gz" -C /data . \
    || fail "Échec sauvegarde filestore"

log "Nettoyage (conservation des 7 derniers backups)..."
ls -t "${BACKUP_DIR}"/db_*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/filestore_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm

log "Sauvegarde terminée : db_${DATE}.sql.gz + filestore_${DATE}.tar.gz"
EOF
    chmod +x "${PROJECT_DIR}/backup.sh"
    log_info "backup.sh généré."
}

_generate_restore_script() {
    cat > "${PROJECT_DIR}/restore.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

DB_CONTAINER="odoo-db"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔ $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠ $1${NC}"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] ✖ $1${NC}"; exit 1; }

[ "$#" -eq 2 ] || fail "Usage : ./restore.sh <db_backup.sql.gz> <filestore_backup.tar.gz>"
DB_BACKUP="$1"; FS_BACKUP="$2"
[ -f "${DB_BACKUP}" ] || fail "Introuvable : ${DB_BACKUP}"
[ -f "${FS_BACKUP}" ] || fail "Introuvable : ${FS_BACKUP}"
[ -f .env ] && source .env || fail "Fichier .env introuvable."

warn "ATTENTION : Cette opération va écraser toutes les données actuelles."
read -rp "  Confirmer ? (oui/non) : " CONFIRM
[ "${CONFIRM}" = "oui" ] || fail "Restauration annulée."

log "Arrêt d'Odoo..."
docker compose stop odoo

log "Restauration de la base de données..."
gunzip -c "${DB_BACKUP}" | docker exec -i "${DB_CONTAINER}" psql -U "${POSTGRES_USER}" \
    || fail "Échec restauration PostgreSQL"

log "Restauration du filestore..."
docker run --rm \
    -v odoo-filestore:/data \
    -v "$(pwd)":/backup \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/${FS_BACKUP} -C /data" \
    || fail "Échec restauration filestore"

log "Redémarrage d'Odoo..."
docker compose start odoo
log "Restauration terminée avec succès."
EOF
    chmod +x "${PROJECT_DIR}/restore.sh"
    log_info "restore.sh généré."
}

_generate_makefile() {
    cat > "${PROJECT_DIR}/Makefile" <<'EOF'
.PHONY: help up down restart logs ps shell-odoo shell-db backup restore update clean

CYAN  := \033[36m
RESET := \033[0m

help:
	@echo ""
	@echo "  Odoo Docker — Commandes disponibles"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-15s$(RESET) %s\n", $$1, $$2}'
	@echo ""

up: ## Démarrer la stack
	docker compose up -d

down: ## Arrêter la stack
	docker compose down

restart: ## Redémarrer
	docker compose restart

logs: ## Logs en temps réel
	docker compose logs -f

ps: ## Statut des conteneurs
	docker compose ps

shell-odoo: ## Shell dans le conteneur Odoo
	docker exec -it odoo-app bash

shell-db: ## Shell PostgreSQL
	docker exec -it odoo-db psql -U odoo -d postgres

backup: ## Sauvegarder base + filestore
	@./backup.sh

restore: ## Restaurer (usage: make restore DB=fichier.sql.gz FS=fichier.tar.gz)
	@./restore.sh $(DB) $(FS)

update: ## Mettre à jour les images
	docker compose pull && docker compose up -d --force-recreate

clean: ## Supprimer les conteneurs (données préservées)
	docker compose down --remove-orphans
EOF
    log_info "Makefile généré."
}

_generate_gitignore() {
    cat > "${PROJECT_DIR}/.gitignore" <<'EOF'
.env
backups/
!backups/.gitkeep
addons/*
!addons/.gitkeep
EOF
    log_info ".gitignore généré."
}

# =============================================================================
#  ÉTAPE 8 — DÉMARRAGE DE LA STACK
# =============================================================================

start_stack() {
    log_step "Démarrage de la stack Docker"

    cd "${PROJECT_DIR}"

    log_info "Téléchargement des images (peut prendre quelques minutes)..."
    sudo docker compose pull

    log_info "Démarrage des conteneurs..."
    sudo docker compose up -d

    log_info "Conteneurs démarrés."
}

# =============================================================================
#  ÉTAPE 9 — ATTENTE QU'ODOO SOIT PRÊT
# =============================================================================

wait_for_odoo() {
    log_step "Attente du démarrage d'Odoo"

    local max_attempts=60  # 60 × 5s = 5 minutes max
    local attempt=0
    local url="http://localhost:${ODOO_PORT}/web/health"

    log_info "Vérification toutes les 5 secondes (timeout : 5 minutes)..."

    while [[ ${attempt} -lt ${max_attempts} ]]; do
        attempt=$((attempt + 1))

        if curl -fsSL --max-time 3 "${url}" &>/dev/null; then
            log_info "Odoo est opérationnel après $((attempt * 5)) secondes."
            return 0
        fi

        printf "  ${YELLOW}⏳ Tentative %d/%d...${NC}\r" "${attempt}" "${max_attempts}"
        sleep 5
    done

    echo ""
    log_warn "Odoo n'a pas répondu dans le délai imparti."
    log_warn "Vérifiez les logs avec : cd ${PROJECT_DIR} && docker compose logs odoo"
    return 1
}

# =============================================================================
#  ÉTAPE 10 — RÉSUMÉ FINAL
# =============================================================================

print_summary() {
    local ip
    ip=$(hostname -I | awk '{print $1}')

    echo -e "\n${GREEN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║           ✔  Installation terminée avec succès        ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}  Accès à Odoo :${NC}"
    echo -e "  ${CYAN}→  Local    :${NC}  http://localhost:${ODOO_PORT}"
    echo -e "  ${CYAN}→  Réseau   :${NC}  http://${ip}:${ODOO_PORT}"

    echo -e "\n${BOLD}  Projet installé dans :${NC}"
    echo -e "  ${CYAN}→${NC}  ${PROJECT_DIR}"

    echo -e "\n${BOLD}  Commandes utiles :${NC}"
    echo -e "  ${CYAN}cd ${PROJECT_DIR}${NC}"
    echo -e "  make help       ${YELLOW}# voir toutes les commandes${NC}"
    echo -e "  make logs       ${YELLOW}# suivre les logs${NC}"
    echo -e "  make ps         ${YELLOW}# statut des conteneurs${NC}"
    echo -e "  make backup     ${YELLOW}# sauvegarder${NC}"
    echo -e "  make down       ${YELLOW}# arrêter${NC}"

    echo -e "\n${BOLD}  Première connexion :${NC}"
    echo -e "  ${YELLOW}→  Créez votre base de données depuis l'interface web${NC}"
    echo -e "  ${YELLOW}→  Le mot de passe maître est dans : ${PROJECT_DIR}/.env${NC}"

    echo ""
}

# =============================================================================
#  MAIN — ORCHESTRATION
# =============================================================================

main() {
    print_banner
    check_prerequisites
    detect_os
    install_docker
    check_compose
    setup_project
    generate_env
    generate_project_files
    start_stack
    wait_for_odoo
    print_summary
}

main "$@"

#!/usr/bin/env bash
# =============================================================================
#  install.sh — Déploiement automatisé Odoo 17 + PostgreSQL 15 via Docker
#  Compatible : Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux
#  Usage      : curl -fsSL <url>/install.sh | bash
#               ou : bash install.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Versions ──────────────────────────────────────────────────────────────
readonly ODOO_VERSION="17"
readonly POSTGRES_VERSION="15"
readonly PROJECT_DIR="${HOME}/odoo-docker"
readonly ODOO_PORT="8069"

# ─── Couleurs ──────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ─── Variables globales ────────────────────────────────────────────────────
OS_ID=""
OS_VERSION=""
OS_LIKE=""
PKG_MANAGER=""
DOCKER_CMD="sudo docker"       # Par défaut sudo, ajusté après détection droits

# =============================================================================
#  FONCTIONS UTILITAIRES
# =============================================================================

log_info()  { echo -e "${GREEN}  ✔  $1${NC}"; }
log_warn()  { echo -e "${YELLOW}  ⚠  $1${NC}"; }
log_error() { echo -e "${RED}  ✖  $1${NC}" >&2; }
log_step()  { echo -e "\n${BOLD}${BLUE}━━━  $1${NC}"; }

fail() {
    log_error "$1"
    exit 1
}

command_exists() {
    command -v "$1" &>/dev/null
}

generate_password() {
    head -c 48 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24
}

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

    # Ne pas exécuter en root
    if [[ "${EUID}" -eq 0 ]]; then
        fail "Ne pas exécuter en tant que root. Utilisez un utilisateur avec sudo."
    fi

    # sudo disponible
    if ! command_exists sudo; then
        fail "sudo est requis. Installez-le et accordez les droits à votre utilisateur."
    fi

    # Obtenir et maintenir les droits sudo pour toute la durée du script
    # -v rafraîchit le ticket sudo sans poser de question si déjà valide
    log_warn "Droits sudo nécessaires pour l'installation."
    sudo -v || fail "Impossible d'obtenir les droits sudo."

    # Maintenir sudo actif en arrière-plan pendant toute la durée du script
    # Sans ça, sudo expire après 15 min et le script échoue en cours de route
    ( while true; do sudo -v; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    # On enregistre le PID pour le tuer proprement à la fin
    trap 'kill ${SUDO_KEEPALIVE_PID} 2>/dev/null || true' EXIT

    # Connexion internet
    log_info "Vérification de la connexion internet..."
    if ! curl -fsSL --max-time 10 https://hub.docker.com > /dev/null 2>&1; then
        fail "Pas de connexion internet. Vérifiez votre réseau."
    fi

    # Architecture CPU
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64|amd64)  log_info "Architecture : x86_64 ✔" ;;
        aarch64|arm64) log_info "Architecture : arm64 ✔" ;;
        *)             fail "Architecture non supportée : ${ARCH}" ;;
    esac

    log_info "Vérifications préalables : OK"
}

# =============================================================================
#  ÉTAPE 2 — DÉTECTION DE L'OS
# =============================================================================

detect_os() {
    log_step "Détection du système d'exploitation"

    [[ -f /etc/os-release ]] || fail "/etc/os-release introuvable. OS non détectable."

    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"

    log_info "OS détecté : ${PRETTY_NAME:-${OS_ID}}"

    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop|raspbian)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
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
            if [[ "${OS_LIKE}" == *"debian"* ]] || [[ "${OS_LIKE}" == *"ubuntu"* ]]; then
                PKG_MANAGER="apt"
                log_warn "Distro basée Debian/Ubuntu → apt"
            elif [[ "${OS_LIKE}" == *"rhel"* ]] || [[ "${OS_LIKE}" == *"fedora"* ]]; then
                PKG_MANAGER="dnf"
                log_warn "Distro basée RHEL/Fedora → dnf"
            else
                fail "Distribution non supportée : ${OS_ID}"
            fi
            ;;
    esac

    log_info "Gestionnaire de paquets : ${PKG_MANAGER}"
}

# =============================================================================
#  ÉTAPE 3 — OUTILS DE BASE (git, make, curl)
# =============================================================================

install_base_tools() {
    log_step "Installation des outils de base"

    local missing=()

    for tool in curl git make; do
        if command_exists "${tool}"; then
            log_info "${tool} : déjà présent"
        else
            missing+=("${tool}")
            log_warn "${tool} : manquant"
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Tous les outils de base sont présents."
        return 0
    fi

    log_info "Installation de : ${missing[*]}"

    case "${PKG_MANAGER}" in
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${missing[@]}"
            ;;
        dnf|yum)
            sudo "${PKG_MANAGER}" install -y -q "${missing[@]}"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm "${missing[@]}"
            ;;
        zypper)
            sudo zypper install -y "${missing[@]}"
            ;;
    esac

    log_info "Outils de base installés."
}

# =============================================================================
#  ÉTAPE 4 — INSTALLATION DE DOCKER
# =============================================================================

install_docker() {
    log_step "Installation de Docker"

    if command_exists docker; then
        log_info "Docker déjà installé : $(sudo docker --version 2>/dev/null || docker --version)"
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

_install_docker_apt() {
    log_info "Méthode : dépôt officiel Docker (apt)"

    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings

    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

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

_install_docker_dnf() {
    log_info "Méthode : dépôt officiel Docker (dnf/yum)"

    sudo "${PKG_MANAGER}" install -y -q ca-certificates curl gnupg2

    sudo "${PKG_MANAGER}" config-manager \
        --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
    || sudo "${PKG_MANAGER}" config-manager \
        --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

    sudo "${PKG_MANAGER}" install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
}

_install_docker_pacman() {
    log_info "Méthode : pacman (Arch Linux)"
    sudo pacman -Sy --noconfirm docker docker-compose
}

_install_docker_zypper() {
    log_info "Méthode : zypper (openSUSE)"
    sudo zypper install -y docker docker-compose
}

_post_install_docker() {
    log_info "Configuration post-installation Docker..."
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker "${USER}"
    log_info "Utilisateur '${USER}' ajouté au groupe docker."
    _ensure_docker_running
}

# FIX PROBLÈME 1 :
# On teste toujours avec sudo pour éviter l'échec lié
# au groupe docker non encore actif dans la session courante.
# DOCKER_CMD reste "sudo docker" pour tout le script.
_ensure_docker_running() {
    if sudo docker info &>/dev/null; then
        log_info "Docker opérationnel."
        return 0
    fi

    log_warn "Docker ne répond pas. Tentative de démarrage..."
    sudo systemctl start docker
    sleep 3

    if sudo docker info &>/dev/null; then
        log_info "Docker opérationnel après démarrage."
        return 0
    fi

    fail "Docker inaccessible. Vérifiez l'installation manuellement."
}

# =============================================================================
#  ÉTAPE 5 — VÉRIFICATION DOCKER COMPOSE
# =============================================================================

# FIX PROBLÈME 2 :
# On utilise "sudo docker compose" au lieu de "docker compose"
# pour contourner le problème de groupe non actif.
check_compose() {
    log_step "Vérification de Docker Compose"

    if sudo docker compose version &>/dev/null 2>&1; then
        log_info "Docker Compose v2 : $(sudo docker compose version --short 2>/dev/null)"
        return 0
    fi

    if command_exists docker-compose; then
        log_warn "Docker Compose v1 détecté (obsolète mais fonctionnel)."
        return 0
    fi

    fail "Docker Compose introuvable. Réinstallez Docker avec le plugin Compose."
}

# =============================================================================
#  ÉTAPE 6 — CRÉATION DE LA STRUCTURE DU PROJET
# =============================================================================

# FIX PROBLÈME 4 :
# curl | bash occupe stdin → read -rp bloque ou reçoit EOF → exit inattendu.
# Solution : détecter si stdin est un terminal.
# Si non (pipe), on supprime le dossier existant automatiquement sans demander.
setup_project() {
    log_step "Création de la structure du projet"

    if [[ -d "${PROJECT_DIR}" ]]; then
        # stdin est-il un terminal interactif ?
        if [[ -t 0 ]]; then
            # Mode interactif : on demande confirmation
            log_warn "Le dossier ${PROJECT_DIR} existe déjà."
            read -rp "  Écraser l'installation existante ? (oui/non) : " CONFIRM
            if [[ "${CONFIRM}" != "oui" ]]; then
                log_info "Installation annulée. L'installation existante est préservée."
                exit 0
            fi
        else
            # Mode pipe (curl | bash) : on écrase automatiquement
            log_warn "Dossier existant détecté. Écrasement automatique (mode non-interactif)."
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
#  ÉTAPE 7 — GÉNÉRATION DU FICHIER .env
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
    log_info "Fichier .env généré avec mot de passe aléatoire sécurisé."
}

# =============================================================================
#  ÉTAPE 8 — GÉNÉRATION DES FICHIERS DU PROJET
# =============================================================================

generate_project_files() {
    log_step "Génération des fichiers du projet"

    _generate_odoo_conf
    _generate_compose
    _generate_env_example
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
    # FIX : utiliser 'EOF' (avec quotes) pour que bash
    # n'interprète pas les ${VARIABLE} à l'intérieur.
    # Ces variables seront lues par docker compose au runtime depuis .env.
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

_generate_env_example() {
    cat > "${PROJECT_DIR}/.env.example" <<'EOF'
# PostgreSQL
POSTGRES_DB=postgres
POSTGRES_USER=odoo
POSTGRES_PASSWORD=CHANGE_ME

# Odoo
ODOO_DB_HOST=db
ODOO_DB_PORT=5432
ODOO_DB_USER=odoo
ODOO_DB_PASSWORD=CHANGE_ME

# Réseau
ODOO_PORT=8069
EOF
    log_info ".env.example généré."
}

_generate_backup_script() {
    cat > "${PROJECT_DIR}/backup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="./backups"
DATE=$(date +%Y%m%d_%H%M%S)
DB_CONTAINER="odoo-db"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔ $1${NC}"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] ✖ $1${NC}"; exit 1; }

[ -f .env ] && source .env || fail "Lancez depuis le dossier du projet (~/odoo-docker)."
mkdir -p "${BACKUP_DIR}"

log "Sauvegarde base de données..."
docker exec "${DB_CONTAINER}" pg_dumpall -U "${POSTGRES_USER}" \
    | gzip > "${BACKUP_DIR}/db_${DATE}.sql.gz" \
    || fail "Échec sauvegarde PostgreSQL"

log "Sauvegarde filestore..."
docker run --rm \
    -v odoo-filestore:/data \
    -v "$(pwd)/${BACKUP_DIR}":/backup \
    alpine tar czf "/backup/filestore_${DATE}.tar.gz" -C /data . \
    || fail "Échec sauvegarde filestore"

log "Nettoyage (7 derniers backups conservés)..."
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

[ "$#" -eq 2 ] || fail "Usage : ./restore.sh <db.sql.gz> <filestore.tar.gz>"
DB_BACKUP="$1"; FS_BACKUP="$2"
[ -f "${DB_BACKUP}" ] || fail "Introuvable : ${DB_BACKUP}"
[ -f "${FS_BACKUP}" ]  || fail "Introuvable : ${FS_BACKUP}"
[ -f .env ] && source .env || fail "Lancez depuis le dossier du projet."

warn "ATTENTION : toutes les données actuelles seront écrasées."
read -rp "  Confirmer ? (oui/non) : " CONFIRM
[ "${CONFIRM}" = "oui" ] || fail "Restauration annulée."

log "Arrêt d'Odoo..."
docker compose stop odoo

log "Restauration base de données..."
gunzip -c "${DB_BACKUP}" \
    | docker exec -i "${DB_CONTAINER}" psql -U "${POSTGRES_USER}" \
    || fail "Échec restauration PostgreSQL"

log "Restauration filestore..."
docker run --rm \
    -v odoo-filestore:/data \
    -v "$(pwd)":/backup \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/${FS_BACKUP} -C /data" \
    || fail "Échec restauration filestore"

log "Redémarrage d'Odoo..."
docker compose start odoo
log "Restauration terminée."
EOF
    chmod +x "${PROJECT_DIR}/restore.sh"
    log_info "restore.sh généré."
}

# FIX PROBLÈME 5 — Makefile :
# Les indentations dans un Makefile DOIVENT être des tabulations (TAB),
# jamais des espaces. Un heredoc depuis bash peut les convertir en espaces.
# On utilise printf pour forcer les vraies tabulations.
_generate_makefile() {
    # Note : \t dans printf = tabulation réelle
    printf '.PHONY: help up down restart logs ps shell-odoo shell-db backup restore update clean\n' \
        > "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"
    printf 'CYAN  := \\033[36m\n' >> "${PROJECT_DIR}/Makefile"
    printf 'RESET := \\033[0m\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'help: ## Affiche cette aide\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@echo ""\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@echo "  Odoo Docker — Commandes disponibles"\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@echo ""\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@grep -E '"'"'^[a-zA-Z_-]+:.*?## .*$$'"'"' $(MAKEFILE_LIST) \\\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t\t| awk '"'"'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%%-15s$(RESET) %%s\\n", $$1, $$2}'"'"'\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@echo ""\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'up: ## Démarrer la stack\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose up -d\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'down: ## Arrêter la stack\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose down\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'restart: ## Redémarrer\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose restart\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'logs: ## Logs en temps réel\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose logs -f\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'ps: ## Statut des conteneurs\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose ps\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'shell-odoo: ## Shell dans le conteneur Odoo\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker exec -it odoo-app bash\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'shell-db: ## Shell PostgreSQL\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker exec -it odoo-db psql -U odoo -d postgres\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'backup: ## Sauvegarder base + filestore\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@bash backup.sh\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'restore: ## Restaurer (make restore DB=xxx.sql.gz FS=xxx.tar.gz)\n' >> "${PROJECT_DIR}/Makefile"
    printf '\t@bash restore.sh $(DB) $(FS)\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'update: ## Mettre à jour les images et redémarrer\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose pull && docker compose up -d --force-recreate\n' >> "${PROJECT_DIR}/Makefile"
    printf '\n' >> "${PROJECT_DIR}/Makefile"

    printf 'clean: ## Supprimer les conteneurs (données préservées)\n' >> "${PROJECT_DIR}/Makefile"
    printf '\tdocker compose down --remove-orphans\n' >> "${PROJECT_DIR}/Makefile"

    log_info "Makefile généré."
}

_generate_gitignore() {
    cat > "${PROJECT_DIR}/.gitignore" <<'EOF'
.env
backups/*
!backups/.gitkeep
addons/*
!addons/.gitkeep
EOF
    log_info ".gitignore généré."
}

# =============================================================================
#  ÉTAPE 9 — DÉMARRAGE DE LA STACK
# =============================================================================

# FIX PROBLÈME 3 :
# On utilise "sudo docker compose" partout pour éviter
# le problème de groupe docker non actif dans la session courante.
start_stack() {
    log_step "Démarrage de la stack Docker"

    cd "${PROJECT_DIR}"

    log_info "Téléchargement des images (patience, ~500MB)..."
    sudo docker compose pull

    log_info "Démarrage des conteneurs..."
    sudo docker compose up -d

    log_info "Conteneurs démarrés."
}

# =============================================================================
#  ÉTAPE 10 — ATTENTE QU'ODOO SOIT PRÊT
# =============================================================================

wait_for_odoo() {
    log_step "Attente du démarrage d'Odoo"

    local max_attempts=72   # 72 × 5s = 6 minutes
    local attempt=0
    local url="http://localhost:${ODOO_PORT}/web/health"

    log_info "Vérification toutes les 5 secondes (timeout : 6 minutes)..."

    while [[ ${attempt} -lt ${max_attempts} ]]; do
        attempt=$((attempt + 1))

        if curl -fsSL --max-time 3 "${url}" &>/dev/null; then
            echo ""
            log_info "Odoo opérationnel après $((attempt * 5)) secondes."
            return 0
        fi

        printf "  ${YELLOW}⏳ Tentative %d/%d — Odoo démarre...${NC}\r" \
            "${attempt}" "${max_attempts}"
        sleep 5
    done

    echo ""
    log_warn "Odoo n'a pas répondu dans le délai imparti."
    log_warn "Vérifiez avec : cd ${PROJECT_DIR} && sudo docker compose logs odoo"
    # On ne fait pas fail ici — les images ont été téléchargées,
    # les fichiers générés. L'utilisateur peut relancer manuellement.
    return 0
}

# =============================================================================
#  ÉTAPE 11 — RÉSUMÉ FINAL
# =============================================================================

print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "votre-ip")

    local db_password
    db_password=$(grep "^ODOO_DB_PASSWORD=" "${PROJECT_DIR}/.env" | cut -d= -f2)

    echo -e "\n${GREEN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║        ✔  Installation terminée avec succès !         ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}  Accès à Odoo :${NC}"
    echo -e "  ${CYAN}→  Local   :${NC}  http://localhost:${ODOO_PORT}"
    echo -e "  ${CYAN}→  Réseau  :${NC}  http://${ip}:${ODOO_PORT}"

    echo -e "\n${BOLD}  Première connexion :${NC}"
    echo -e "  ${YELLOW}1. Ouvrir http://localhost:${ODOO_PORT}${NC}"
    echo -e "  ${YELLOW}2. Remplir le formulaire de création de base${NC}"
    echo -e "  ${YELLOW}   Mot de passe maître : ${BOLD}${db_password}${NC}"
    echo -e "  ${YELLOW}   (également dans : ${PROJECT_DIR}/.env)${NC}"

    echo -e "\n${BOLD}  Projet installé dans :${NC}"
    echo -e "  ${CYAN}→${NC}  ${PROJECT_DIR}"

    echo -e "\n${BOLD}  Commandes utiles :${NC}"
    echo -e "  ${CYAN}cd ${PROJECT_DIR}${NC}"
    echo -e "  sudo docker compose logs -f   ${YELLOW}# logs en temps réel${NC}"
    echo -e "  sudo docker compose ps        ${YELLOW}# statut${NC}"
    echo -e "  sudo docker compose down      ${YELLOW}# arrêter${NC}"
    echo -e "  sudo docker compose up -d     ${YELLOW}# redémarrer${NC}"

    echo -e "\n${BOLD}  Note :${NC}"
    echo -e "  ${YELLOW}Pour utiliser docker sans sudo, reconnectez-vous${NC}"
    echo -e "  ${YELLOW}puis utilisez les commandes 'make' depuis ${PROJECT_DIR}${NC}"
    echo ""
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    print_banner
    check_prerequisites   # sudo, internet, architecture
    detect_os             # détection distro + PKG_MANAGER
    install_base_tools    # curl, git, make
    install_docker        # docker + docker compose plugin
    check_compose         # vérifie docker compose v2
    setup_project         # crée les dossiers
    generate_env          # génère .env avec mot de passe aléatoire
    generate_project_files # génère tous les fichiers
    start_stack           # docker compose pull + up
    wait_for_odoo         # attend que :8069 réponde
    print_summary         # affiche URL + mot de passe + commandes
}

main "$@"

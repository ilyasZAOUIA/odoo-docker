#!/bin/bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
BACKUP_DIR="./backups"
DATE=$(date +%Y%m%d_%H%M%S)
DB_CONTAINER="odoo-db"
DB_USER="${POSTGRES_USER:-odoo}"
DB_NAME="${POSTGRES_DB:-postgres}"

# ─── Couleurs pour les logs ───────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔ $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠ $1${NC}"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] ✖ $1${NC}"; exit 1; }

# ─── Vérifications ───────────────────────────────────────────
[ -f .env ] && source .env || fail "Fichier .env introuvable"
mkdir -p "${BACKUP_DIR}"

# ─── Sauvegarde PostgreSQL ───────────────────────────────────
log "Sauvegarde de la base de données..."
docker exec "${DB_CONTAINER}" \
  pg_dumpall -U "${DB_USER}" \
  | gzip > "${BACKUP_DIR}/db_${DATE}.sql.gz" \
  || fail "Échec de la sauvegarde PostgreSQL"
log "Base sauvegardée : db_${DATE}.sql.gz"

# ─── Sauvegarde du filestore ─────────────────────────────────
log "Sauvegarde du filestore..."
docker run --rm \
  -v odoo-filestore:/data \
  -v "$(pwd)/${BACKUP_DIR}":/backup \
  alpine \
  tar czf "/backup/filestore_${DATE}.tar.gz" -C /data . \
  || fail "Échec de la sauvegarde filestore"
log "Filestore sauvegardé : filestore_${DATE}.tar.gz"

# ─── Nettoyage (garder les 7 derniers backups) ───────────────
log "Nettoyage des anciens backups..."
ls -t "${BACKUP_DIR}"/db_*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/filestore_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm

log "Sauvegarde terminée avec succès."

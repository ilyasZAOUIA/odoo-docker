#!/bin/bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
DB_CONTAINER="odoo-db"
BACKUP_DIR="./backups"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔ $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠ $1${NC}"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] ✖ $1${NC}"; exit 1; }

# ─── Arguments ───────────────────────────────────────────────
[ "$#" -eq 2 ] || fail "Usage: ./restore.sh <db_backup.sql.gz> <filestore_backup.tar.gz>"
DB_BACKUP="$1"
FS_BACKUP="$2"

[ -f "${DB_BACKUP}" ]  || fail "Fichier introuvable : ${DB_BACKUP}"
[ -f "${FS_BACKUP}" ]  || fail "Fichier introuvable : ${FS_BACKUP}"

[ -f .env ] && source .env || fail "Fichier .env introuvable"

# ─── Confirmation ─────────────────────────────────────────────
warn "ATTENTION : Cette opération va écraser les données actuelles."
read -rp "Confirmer ? (oui/non) : " CONFIRM
[ "${CONFIRM}" = "oui" ] || fail "Restauration annulée."

# ─── Arrêt d'Odoo ─────────────────────────────────────────────
log "Arrêt du service Odoo..."
docker compose stop odoo

# ─── Restauration PostgreSQL ──────────────────────────────────
log "Restauration de la base de données..."
gunzip -c "${DB_BACKUP}" | docker exec -i "${DB_CONTAINER}" \
  psql -U "${POSTGRES_USER}" \
  || fail "Échec de la restauration PostgreSQL"
log "Base restaurée."

# ─── Restauration filestore ───────────────────────────────────
log "Restauration du filestore..."
docker run --rm \
  -v odoo-filestore:/data \
  -v "$(pwd)":/backup \
  alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/${FS_BACKUP} -C /data" \
  || fail "Échec de la restauration filestore"
log "Filestore restauré."

# ─── Redémarrage ──────────────────────────────────────────────
log "Redémarrage d'Odoo..."
docker compose start odoo
log "Restauration terminée avec succès."

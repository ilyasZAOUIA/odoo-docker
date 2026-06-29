.PHONY: help up down restart logs ps shell-odoo shell-db backup restore update clean

# ─── Couleurs ─────────────────────────────────────────────────
CYAN  := \033[36m
RESET := \033[0m

help: ## Affiche cette aide
	@echo ""
	@echo "  Odoo Docker Stack — Commandes disponibles"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-15s$(RESET) %s\n", $$1, $$2}'
	@echo ""

up: ## Démarrer la stack
	docker compose up -d

down: ## Arrêter la stack
	docker compose down

restart: ## Redémarrer la stack
	docker compose restart

logs: ## Suivre les logs en temps réel
	docker compose logs -f

ps: ## Statut des conteneurs
	docker compose ps

shell-odoo: ## Shell dans le conteneur Odoo
	docker exec -it odoo-app bash

shell-db: ## Shell PostgreSQL
	docker exec -it odoo-db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

backup: ## Sauvegarder la base et le filestore
	@./backup.sh

restore: ## Restaurer (usage: make restore DB=... FS=...)
	@./restore.sh $(DB) $(FS)

update: ## Mettre à jour les images et redémarrer
	docker compose pull
	docker compose up -d --force-recreate

clean: ## Supprimer les conteneurs (données préservées)
	docker compose down --remove-orphans

## Prérequis

### Machine vierge — Installation en une commande

Seul `curl` est nécessaire. Installez-le selon votre distribution,
puis lancez le script d'installation.

**Ubuntu / Debian**
```bash
sudo apt-get install -y curl && \
curl -fsSL https://raw.githubusercontent.com/tonpseudo/odoo-docker/main/install.sh | bash
```

**CentOS / RHEL / Rocky Linux**
```bash
sudo yum install -y curl && \
curl -fsSL https://raw.githubusercontent.com/tonpseudo/odoo-docker/main/install.sh | bash
```

**Fedora**
```bash
sudo dnf install -y curl && \
curl -fsSL https://raw.githubusercontent.com/tonpseudo/odoo-docker/main/install.sh | bash
```

**Arch Linux / Manjaro**
```bash
sudo pacman -Sy --noconfirm curl && \
curl -fsSL https://raw.githubusercontent.com/tonpseudo/odoo-docker/main/install.sh | bash
 ```
puis faire: docker compse down -v 
ensuit : docker compose up -d
> Le script installe automatiquement : `git`, `make`, `docker`, `docker compose`

---

### Développeur qui clone le repo

Si vous préférez cloner et configurer manuellement :

**Étape 1 — Installer les outils**

Ubuntu / Debian :
```bash
sudo apt-get update
sudo apt-get install -y git make curl
```

CentOS / RHEL / Rocky :
```bash
sudo yum install -y git make curl
```

Fedora :
```bash
sudo dnf install -y git make curl
```

Arch Linux :
```bash
sudo pacman -Sy --noconfirm git make curl
```

**Étape 2 — Installer Docker**

Toutes distributions (script officiel Docker) :
```bash
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER
newgrp docker
```

**Étape 3 — Cloner et démarrer**

```bash
git clone https://github.com/tonpseudo/odoo-docker
cd odoo-docker
cp .env.example .env
nano .env
make up
```
// make up :	Démarre la stack Odoo + PostgreSQL en arrière-plan
// make down :	Arrête et supprime les conteneurs (les données restent préservées)
// make restart :	Redémarre l'application
// make logs :	Affiche les logs d'Odoo en temps réel (pratique pour le débug)
// make ps :	Vérifie l'état de santé des conteneurs
// make backup :	Lance une sauvegarde complète de la base de données et du filestore
// make shell-odoo :	Ouvre un terminal bash à l'intérieur du conteneur Odoo
// make clean :	Arrête proprement la stack et nettoie les réseaux orphelins

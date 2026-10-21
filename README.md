# wazuh-lab

Stack Wazuh single-node (manager, indexer, dashboard) déployée avec Docker Compose.

## Prérequis

- Docker et Docker Compose
- Un fichier `.env` créé à partir de `.env.example` (voir ci-dessous)

## Configuration des mots de passe

```bash
cp .env.example .env
nano .env        # remplir les vrais mots de passe
```

Le fichier `.env` n'est jamais versionné (il est dans `.gitignore`).

## Démarrage (à suivre dans cet ordre)

> **Important : ne lance pas directement `docker compose up -d`.**
> Les certificats doivent d'abord être générés dans un dossier propre.
> Si le dossier `config/wazuh_indexer_ssl_certs` contient des dossiers au lieu de
> fichiers `.pem`, les conteneurs plantent avec l'erreur `is a directory`
> ou `Are you trying to mount a directory onto a file`.

### 1. Arrêter les conteneurs existants

```bash
docker compose down
```

### 2. Nettoyer et recréer le dossier des certificats

```bash
sudo rm -rf config/wazuh_indexer_ssl_certs
mkdir -p config/wazuh_indexer_ssl_certs
ls -la config/wazuh_indexer_ssl_certs/    # doit être vide
```

### 3. Générer les certificats

```bash
docker compose run --rm generator
ls -la config/wazuh_indexer_ssl_certs/
```

Vérifie que les 10 entrées sont bien des **fichiers** (la ligne commence par `-`,
pas par `d`) :

`root-ca.pem`, `root-ca-manager.pem`, `admin.pem`, `admin-key.pem`,
`wazuh.indexer.pem`, `wazuh.indexer-key.pem`, `wazuh.manager.pem`,
`wazuh.manager-key.pem`, `wazuh.dashboard.pem`, `wazuh.dashboard-key.pem`.

### 4. Lancer la stack

```bash
docker compose up -d
```

Attends 1 à 2 minutes que le manager et l'API démarrent, puis ouvre
https://localhost (le certificat est auto-signé, accepte l'avertissement du navigateur).

## Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `Are you trying to mount a directory onto a file` | Un chemin de certificat est un dossier | Refaire les étapes 1 à 4 |
| `/etc/ssl/filebeat.pem: is a directory` (logs du manager) | Idem | Refaire les étapes 1 à 4 |
| `cp: cannot overwrite directory ...` (générateur) | Des conteneurs ont recréé les chemins en dossiers | `docker compose down` puis refaire les étapes 2 à 4 |
| Erreur 3000 dans le dashboard | Mot de passe `wazuh-wui` différent entre l'API et le dashboard, ou manager pas prêt | Vérifier `API_PASSWORD` et `config/wazuh_dashboard/wazuh.yml`, puis attendre le démarrage du manager |

## Repartir de zéro (supprime toutes les données)

```bash
docker compose down -v
sudo rm -rf config/wazuh_indexer_ssl_certs
mkdir -p config/wazuh_indexer_ssl_certs
docker compose run --rm generator
docker compose up -d
```

`-v` supprime les volumes : agents enregistrés, alertes et mots de passe modifiés
via l'API sont perdus.

## Notes

- Les certificats et clés (`*.pem`, `*.key`) ne doivent jamais être poussés sur GitHub.
- Les variables `INDEXER_PASSWORD` et `API_PASSWORD` ne sont lues qu'à la première
  initialisation. Pour changer un mot de passe ensuite, voir la documentation Wazuh
  (hash dans `internal_users.yml` + `securityadmin` pour l'indexer, API ou dashboard
  pour `wazuh-wui`).

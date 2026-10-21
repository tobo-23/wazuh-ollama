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

Le service `generator` a `profiles: ["certs"]` dans `docker-compose.yml` : il ne démarre
**jamais** avec `docker compose up -d`, uniquement avec `docker compose run --rm generator`.
Sans ce profil, il régénère de nouveaux certificats à chaque démarrage et les conteneurs
se retrouvent avec des certificats incohérents (erreur 500 dans le dashboard).

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

## Changer un mot de passe (admin ou kibanaserver)

Changer la valeur dans `docker-compose.yml` ne suffit pas : l'indexer stocke un hash
du mot de passe. Le script `change-password.sh` automatise toute la procédure
officielle Wazuh.

```bash
chmod +x change-password.sh        # une seule fois

./change-password.sh               # change le mot de passe de admin
./change-password.sh kibanaserver  # change celui de kibanaserver
```

Le script demande le nouveau mot de passe (saisie masquée, avec confirmation), puis :

1. vérifie la complexité (8 à 64 caractères, majuscule, minuscule, chiffre, symbole, sans espace) ;
2. arrête la stack (`docker compose down`) ;
3. génère le hash avec l'image `wazuh-indexer` du compose ;
4. écrit le mot de passe dans `.env` (`INDEXER_PASSWORD` pour admin, `DASHBOARD_PASSWORD` pour kibanaserver) et fait référencer `${VARIABLE}` par `docker-compose.yml` ;
5. met à jour le hash dans `config/wazuh_indexer/internal_users.yml` ;
6. relance la stack (`docker compose up -d wazuh.manager wazuh.indexer wazuh.dashboard`, sans le generator) ;
7. applique les changements avec `securityadmin.sh` (réessaie jusqu'à 5 minutes, le temps que l'indexer démarre).

Une fois terminé, rafraîchis le dashboard et connecte-toi avec le nouveau mot de passe.

À savoir :

- Le mot de passe est stocké dans `.env` (permissions `600`), **pas** dans `docker-compose.yml`.
  Le compose ne contient que `${INDEXER_PASSWORD}` / `${DASHBOARD_PASSWORD}` et peut donc être
  poussé sur GitHub sans fuite. `.env` est ajouté automatiquement à `.gitignore`.
- Les valeurs de `.env` sont écrites entre apostrophes : aucun `$` à doubler. En contrepartie,
  le mot de passe ne peut pas contenir d'apostrophe (`'`) ni d'espace.
- Des sauvegardes `*.bak-<date>` (compose, `internal_users.yml`, `.env`) sont créées avant
  modification. Elles contiennent l'ancien mot de passe ou l'ancien hash : `*.bak-*` est
  ajouté automatiquement à `.gitignore`.
- Si ton compose contient encore des mots de passe en clair, le script les remplace
  par `${VARIABLE}` pour la variable modifiée. Fais-le une fois pour `admin` et une fois pour
  `kibanaserver`. `API_PASSWORD` n'est pas géré (voir plus bas) : pense à le déplacer dans
  `.env` à la main (`API_PASSWORD=${API_PASSWORD}` dans le compose).
- Après un changement de mot de passe, `.env` est la **seule** source à modifier côté compose.
  Un simple `docker compose restart` ne relit pas `.env` : utilise `docker compose up -d`.
- Le script ne gère pas `wazuh-wui` (API Wazuh). Pour celui-ci : dashboard, *Server management →
  Security → Users*, puis mets le même mot de passe dans `API_PASSWORD` et
  `config/wazuh_dashboard/wazuh.yml`, et recrée le dashboard
  (`docker compose up -d --force-recreate wazuh.dashboard`).
- Si `securityadmin.sh` échoue, consulte `docker compose logs --tail=50 wazuh.indexer`.

## Notes

- Les certificats et clés (`*.pem`, `*.key`) ne doivent jamais être poussés sur GitHub.
- Les variables `INDEXER_PASSWORD` et `API_PASSWORD` ne sont lues qu'à la première
  initialisation. Pour changer un mot de passe ensuite, utilise `change-password.sh`
  (voir la section ci-dessus).
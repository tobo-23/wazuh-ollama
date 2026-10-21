#!/usr/bin/env bash
# change-password.sh
# Change le mot de passe d'un utilisateur interne Wazuh (admin ou kibanaserver)
# dans une stack Docker Compose single-node :
#   1. écrit le mot de passe dans .env (INDEXER_PASSWORD ou DASHBOARD_PASSWORD) et
#      fait référencer ${VARIABLE} par docker-compose.yml (plus de mot de passe en clair)
#   2. génère le hash et met à jour config/wazuh_indexer/internal_users.yml
#   3. relance la stack
#   4. applique les changements avec securityadmin.sh
#
# Usage : ./change-password.sh [admin|kibanaserver]    (défaut : admin)

set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
USERS_FILE="config/wazuh_indexer/internal_users.yml"
INDEXER_SERVICE="wazuh.indexer"
MAX_RETRIES=20      # 20 x 15 s = 5 minutes max d'attente
RETRY_DELAY=15

USER_NAME="${1:-admin}"

# ---------- Vérifications ----------
case "$USER_NAME" in
  admin)        ENV_VAR="INDEXER_PASSWORD" ;;
  kibanaserver) ENV_VAR="DASHBOARD_PASSWORD" ;;
  *) echo "Utilisateur invalide : $USER_NAME (choix : admin, kibanaserver)"; exit 1 ;;
esac

for f in "$COMPOSE_FILE" "$USERS_FILE"; do
  [[ -f "$f" ]] || { echo "Fichier introuvable : $f (lance le script depuis la racine du projet)"; exit 1; }
done
command -v docker >/dev/null || { echo "docker n'est pas installé"; exit 1; }

# Les certificats doivent déjà exister (le generator n'est pas relancé par ce script)
CERTS_DIR="config/wazuh_indexer_ssl_certs"
for c in root-ca.pem root-ca-manager.pem admin.pem admin-key.pem \
         wazuh.indexer.pem wazuh.indexer-key.pem wazuh.manager.pem \
         wazuh.manager-key.pem wazuh.dashboard.pem wazuh.dashboard-key.pem; do
  [[ -f "$CERTS_DIR/$c" ]] || {
    echo "Certificat manquant ou invalide : $CERTS_DIR/$c"
    echo "Génère-les d'abord : docker compose run --rm generator (voir le README)."
    exit 1
  }
done

# ---------- Saisie du mot de passe ----------
read -rsp "Nouveau mot de passe pour '$USER_NAME' : " PW; echo
read -rsp "Confirme le mot de passe : " PW2; echo
[[ "$PW" == "$PW2" ]] || { echo "Les mots de passe ne correspondent pas."; exit 1; }

if (( ${#PW} < 8 || ${#PW} > 64 )); then echo "Le mot de passe doit faire entre 8 et 64 caractères."; exit 1; fi
[[ "$PW" =~ [A-Z] ]]        || { echo "Il manque une majuscule."; exit 1; }
[[ "$PW" =~ [a-z] ]]        || { echo "Il manque une minuscule."; exit 1; }
[[ "$PW" =~ [0-9] ]]        || { echo "Il manque un chiffre."; exit 1; }
[[ "$PW" =~ [^A-Za-z0-9] ]] || { echo "Il manque un caractère spécial."; exit 1; }
[[ "$PW" =~ [[:space:]] ]]  && { echo "Pas d'espace dans le mot de passe."; exit 1; }
[[ "$PW" == *"'"* ]]        && { echo "Pas d'apostrophe (') dans le mot de passe."; exit 1; }

# ---------- 1. Arrêt de la stack ----------
echo "==> Arrêt de la stack"
docker compose down

# ---------- 2. Génération du hash ----------
INDEXER_IMAGE=$(awk '/image:.*wazuh-indexer/ {print $2; exit}' "$COMPOSE_FILE")
[[ -n "$INDEXER_IMAGE" ]] || { echo "Image wazuh-indexer introuvable dans $COMPOSE_FILE"; exit 1; }

echo "==> Génération du hash avec $INDEXER_IMAGE"
HASH=$(docker run --rm "$INDEXER_IMAGE" \
  bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$PW" 2>/dev/null \
  | grep -E '^\$2[aby]\$' | tail -n 1)
[[ -n "$HASH" ]] || { echo "Échec de la génération du hash."; exit 1; }

# ---------- Sauvegardes ----------
TS=$(date +%Y%m%d-%H%M%S)
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak-${TS}"
cp "$USERS_FILE"   "${USERS_FILE}.bak-${TS}"
[[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "${ENV_FILE}.bak-${TS}"
echo "==> Sauvegardes : *.bak-${TS}"

# ---------- 3a. docker-compose.yml : utiliser ${VARIABLE} au lieu du mot de passe en clair ----------
# (sans effet si le compose utilise déjà la variable)
echo "==> $COMPOSE_FILE : $ENV_VAR référence désormais \${$ENV_VAR}"
ENV_VAR="$ENV_VAR" awk '
  {
    pat = "^[ \t]*-[ \t]*" ENVIRON["ENV_VAR"] "="
    if (match($0, pat)) { print substr($0, 1, RLENGTH) "${" ENVIRON["ENV_VAR"] "}" }
    else print
  }' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"

# ---------- 3b. .env : écrire le mot de passe ----------
# Entre apostrophes : Compose ne l'interprète pas, donc pas besoin de doubler les '$'
echo "==> Mise à jour de $ENV_FILE ($ENV_VAR)"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
if grep -qE "^${ENV_VAR}=" "$ENV_FILE"; then
  ENV_VAR="$ENV_VAR" PW_VALUE="'${PW}'" awk '
    index($0, ENVIRON["ENV_VAR"] "=") == 1 { print ENVIRON["ENV_VAR"] "=" ENVIRON["PW_VALUE"]; next }
    { print }' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
else
  printf "%s='%s'\n" "$ENV_VAR" "$PW" >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

# .env ne doit jamais être poussé sur GitHub
if [[ -f .gitignore ]] && ! grep -qxE '\.env|/\.env' .gitignore; then
  printf '\n.env\n' >> .gitignore
  echo "==> '.env' ajouté à .gitignore"
fi
if [[ -f .gitignore ]] && ! grep -qxF '*.bak-*' .gitignore; then
  printf '*.bak-*\n' >> .gitignore
  echo "==> '*.bak-*' ajouté à .gitignore"
fi

# ---------- 4. Mise à jour de internal_users.yml ----------
echo "==> Mise à jour du hash de '$USER_NAME' dans $USERS_FILE"
USER_NAME="$USER_NAME" NEW_HASH="$HASH" awk '
  $0 ~ "^" ENVIRON["USER_NAME"] ":" { in_block = 1; print; next }
  in_block && /^[^ \t#]/            { in_block = 0 }
  in_block && /^[ \t]+hash:/ {
    match($0, /^[ \t]+/)
    print substr($0, 1, RLENGTH) "hash: \"" ENVIRON["NEW_HASH"] "\""
    in_block = 0
    next
  }
  { print }' "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

grep -qF "$HASH" "$USERS_FILE" || { echo "Le hash n'a pas été écrit dans $USERS_FILE"; exit 1; }

# ---------- 5. Démarrage ----------
echo "==> Démarrage de la stack"
docker compose up -d wazuh.manager wazuh.indexer wazuh.dashboard

# ---------- 6. securityadmin.sh ----------
echo "==> Application des changements avec securityadmin.sh (attente de l'indexer)"
SECURITYADMIN_CMD='
  export INSTALLATION_DIR=/usr/share/wazuh-indexer
  export CONFIG_DIR=$INSTALLATION_DIR/config
  export JAVA_HOME=$INSTALLATION_DIR/jdk
  bash $INSTALLATION_DIR/plugins/opensearch-security/tools/securityadmin.sh \
    -cd $CONFIG_DIR/opensearch-security/ -nhnv \
    -cacert $CONFIG_DIR/certs/root-ca.pem \
    -cert   $CONFIG_DIR/certs/admin.pem \
    -key    $CONFIG_DIR/certs/admin-key.pem \
    -p 9200 -icl
'

for ((i = 1; i <= MAX_RETRIES; i++)); do
  if docker compose exec -T "$INDEXER_SERVICE" bash -c "$SECURITYADMIN_CMD" >/tmp/securityadmin.log 2>&1; then
    echo "==> securityadmin.sh : succès"
    echo
    echo "Terminé. Rafraîchis le dashboard et connecte-toi avec le nouveau mot de passe de '$USER_NAME'."
    exit 0
  fi
  echo "   Indexer pas encore prêt (essai $i/$MAX_RETRIES), nouvelle tentative dans ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
done

echo "Échec de securityadmin.sh après $MAX_RETRIES essais. Dernière sortie :"
tail -n 30 /tmp/securityadmin.log
echo "Logs de l'indexer : docker compose logs --tail=50 $INDEXER_SERVICE"
exit 1
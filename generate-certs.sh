#!/usr/bin/env bash
set -e

docker compose -f generate-indexer-certs.yml run --rm generator

sudo chown nassim:nassim config/wazuh_indexer_ssl_certs
sudo chmod 700 config/wazuh_indexer_ssl_certs

echo "Certificats générés ; dossier accessible à l'utilisateur de base."
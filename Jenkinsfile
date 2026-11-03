// =====================================================================
// Jenkinsfile : équivalent du workflow GitHub Actions "CI"
//
// Prérequis sur l'agent Jenkins :
//   - Docker + plugin Compose v2 (commande `docker compose`)
//   - l'utilisateur jenkins dans le groupe docker
//   - git, curl, python3
//   - job de type "Multibranch Pipeline" + webhook GitHub
// =====================================================================

// Images analysées par Trivy (équivalent de la matrice GitHub)
def TRIVY_IMAGES = [
  'ollama/ollama:latest',
  'ghcr.io/open-webui/open-webui:main-slim',
  'docker.n8n.io/n8nio/n8n:2.44.6',
  'traefik:v3.0',
  'wazuh/wazuh-manager:4.14.9',
  'wazuh/wazuh-indexer:4.14.9',
  'wazuh/wazuh-dashboard:4.14.9',
]

// Build lancé à la main depuis l'interface Jenkins (= workflow_dispatch)
def isManualBuild() {
  return currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause').size() > 0
}

// Smoke test lancé : push sur main, ou build manuel avec le bon choix de stack
def shouldRunSmoke(String stack) {
  if (isManualBuild()) {
    return params.STACK == 'all' || params.STACK == stack
  }
  return env.BRANCH_NAME == 'main'
}

pipeline {
  agent any

  parameters {
    choice(name: 'STACK',
           choices: ['all', 'wazuh', 'ollama', 'n8n'],
           description: 'Stack à tester (smoke test), pour un lancement manuel')
  }

  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
    // Les smoke tests utilisent des ports fixes (9200, 11434, 5678...) :
    // on interdit deux builds en parallèle sur le même agent
    disableConcurrentBuilds()
  }

  stages {

    // ---------------------------------------------------------------
    // 1. Validation statique (rapide) : compose, YAML, scripts bash
    // ---------------------------------------------------------------
    stage('Validate') {
      parallel {

        stage('Valider les docker-compose') {
          steps {
            sh '''
              for f in $(find . -name 'docker-compose.y*ml' -not -path './.git/*'); do
                d=$(dirname "$f")
                echo "== $f"
                [ -f "$d/.env.example" ] && cp "$d/.env.example" "$d/.env"
                (cd "$d" && docker compose -f "$(basename "$f")" config -q)
              done
            '''
          }
        }

        stage('Lint YAML') {
          steps {
            sh '''
              docker run --rm -v "$PWD":/data cytopia/yamllint \
                --no-warnings \
                -d "{extends: relaxed, rules: {line-length: disable, trailing-spaces: disable, new-line-at-end-of-file: disable}}" .
            '''
          }
        }

        stage('Analyser les scripts bash') {
          steps {
            sh '''
              files=$(git ls-files '*.sh')
              if [ -z "$files" ]; then
                echo "Aucun script .sh à analyser"
              else
                docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable --severity=warning $files
              fi
            '''
          }
        }
      }
    }

    // ---------------------------------------------------------------
    // 2. Sécurité + 3. Smoke tests + Trivy (en parallèle, après Validate)
    // ---------------------------------------------------------------
    stage('Suite') {
      parallel {

        // ----------------------- Sécurité -----------------------
        stage('Sécurité') {
          steps {
            sh '''
              bad=$(git ls-files | grep -E '(^|/)\\.env$|\\.pem$|\\.key$|\\.gguf$|\\.bak-' || true)
              if [ -n "$bad" ]; then
                echo "Fichiers sensibles versionnés :"
                echo "$bad"
                exit 1
              fi
            '''
            // Gitleaks analyse tout l'historique : désactiver le "shallow clone"
            // dans la config du job (Behaviours > Advanced clone behaviours)
            sh '''
              docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/repo \
                zricethezav/gitleaks:latest detect --source /repo --no-banner --redact
            '''
          }
        }

        // ----------------------- Smoke tests -----------------------
        // Exécutés l'un après l'autre : ils partagent les mêmes ports sur l'agent
        stage('Smoke tests') {
          stages {

            stage('Smoke Wazuh') {
              when { expression { shouldRunSmoke('wazuh') } }
              steps {
                // Réglage noyau requis par l'indexer (OpenSearch), sans sudo
                sh 'docker run --rm --privileged --pid=host alpine sysctl -w vm.max_map_count=262144'

                sh '''
                  cp .env.example .env
                  mkdir -p config/wazuh_indexer_ssl_certs
                  docker compose run --rm generator
                  ls -la config/wazuh_indexer_ssl_certs/
                '''

                sh 'docker compose up -d wazuh.manager wazuh.indexer wazuh.dashboard'

                timeout(time: 10, unit: 'MINUTES') {
                  sh '''#!/bin/bash
                    # 200 = répond, 401 = répond mais demande un mot de passe : dans les deux cas l'indexer est up
                    for i in $(seq 1 30); do
                      code=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200 || true)
                      if [ "$code" = "200" ] || [ "$code" = "401" ]; then
                        echo "Indexer OK (HTTP $code)"; exit 0
                      fi
                      echo "Essai $i/30 : HTTP $code"
                      sleep 10
                    done
                    exit 1
                  '''
                }
              }
              post {
                failure { sh 'docker compose logs --tail=100' }
                always {
                  sh '''
                    docker compose down -v || true
                    # Les certificats générés par le conteneur appartiennent à root :
                    # on rend la main à jenkins pour que le nettoyage du workspace fonctionne
                    docker run --rm -v "$PWD/config":/w alpine chown -R "$(id -u):$(id -g)" /w || true
                  '''
                }
              }
            }

            stage('Smoke Ollama') {
              when { expression { shouldRunSmoke('ollama') } }
              environment {
                MODEL = 'qwen2.5:0.5b'   // petit modèle (~400 Mo), assez rapide sur CPU
              }
              steps {
                dir('ollama') {
                  sh 'docker compose up -d'

                  sh '''#!/bin/bash
                    wait_for() {
                      local url="$1" expected="$2"; shift 2
                      for i in $(seq 1 60); do
                        if curl -fsS "$@" "$url" 2>/dev/null | grep -q "$expected"; then
                          echo "OK : $url"; return 0
                        fi
                        echo "Essai $i/60 : $url"; sleep 5
                      done
                      echo "ÉCHEC : $url"; return 1
                    }
                    wait_for http://localhost:11434 "Ollama is running"
                    wait_for http://localhost:8085/health "true"
                  '''

                  // open-webui -> ollama via le réseau interne
                  sh '''#!/bin/bash
                    docker compose exec -T open-webui python -c "import urllib.request; print(urllib.request.urlopen('http://ollama:11434', timeout=10).read().decode())" | grep -q "Ollama is running"
                    echo "open-webui joint bien ollama"
                  '''

                  timeout(time: 10, unit: 'MINUTES') {
                    sh '''#!/bin/bash
                      for i in 1 2 3; do
                        docker compose exec -T ollama ollama pull "$MODEL" && exit 0
                        echo "Échec du téléchargement ($i/3), nouvel essai..."; sleep 10
                      done
                      exit 1
                    '''
                  }

                  sh '''#!/bin/bash
                    docker compose exec -T ollama ollama list | grep -q "$MODEL"
                    curl -fsS http://localhost:11434/api/tags | grep -q "$MODEL"
                    echo "Modèle $MODEL présent"
                  '''

                  timeout(time: 5, unit: 'MINUTES') {
                    sh '''#!/bin/bash
                      set -e
                      payload=$(printf '{"model":"%s","prompt":"Say hello in one short sentence.","stream":false,"options":{"num_predict":20}}' "$MODEL")
                      answer=$(curl -fsS http://localhost:11434/api/generate -d "$payload")
                      echo "$answer"
                      echo "$answer" | grep -q '"done":true'
                      echo "$answer" | python3 -c "import sys, json; r = json.load(sys.stdin)['response']; assert r.strip(), 'réponse vide'; print('Réponse :', r)"
                    '''
                  }
                }
              }
              post {
                failure { dir('ollama') { sh 'docker compose logs --tail=100' } }
                always  { dir('ollama') { sh 'docker compose down -v || true' } }
              }
            }

            stage('Smoke n8n') {
              when { expression { shouldRunSmoke('n8n') } }
              steps {
                dir('n8n') {
                  sh '''
                    mkdir -p local-files
                    docker compose up -d
                  '''

                  sh '''#!/bin/bash
                    wait_for() {
                      local url="$1" expected="$2"; shift 2
                      for i in $(seq 1 40); do
                        if curl -fsS "$@" "$url" 2>/dev/null | grep -q "$expected"; then
                          echo "OK : $url"; return 0
                        fi
                        echo "Essai $i/40 : $url"; sleep 5
                      done
                      echo "ÉCHEC : $url"; return 1
                    }
                    wait_for http://localhost:5678/healthz "ok"
                    wait_for http://localhost:8080/api/overview "routers"
                    # Le routage Traefik : n8n.local doit mener à n8n
                    wait_for http://localhost/healthz "ok" -H "Host: n8n.local"
                  '''
                }
              }
              post {
                failure { dir('n8n') { sh 'docker compose logs --tail=100' } }
                always  { dir('n8n') { sh 'docker compose down -v || true' } }
              }
            }
          }
        }

        // ----------------------- Trivy -----------------------
        stage('Trivy') {
          steps {
            script {
              // Séquentiel : les scans partagent le même cache de base de vulnérabilités
              TRIVY_IMAGES.each { img ->
                // Équivalent de fail-fast: false + exit-code 0 : un échec n'arrête pas les autres
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                  sh """
                    docker run --rm -v trivy-cache:/root/.cache/ aquasec/trivy:latest image \
                      --severity HIGH,CRITICAL --ignore-unfixed --exit-code 0 ${img}
                  """
                }
              }
            }
          }
        }
      }
    }
  }

  post {
    failure { echo 'CI échouée, consultez les logs de l\'étape en erreur.' }
  }
}
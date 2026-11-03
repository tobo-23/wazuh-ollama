pipeline {
  agent any

  environment {
    DEPLOY_HOST = 'nas-server@192.168.1.100'
    DEPLOY_DIR  = '/opt/wazuh-ollama'
  }

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  stages {
    stage('Lint') {
      steps {
        sh 'docker run --rm -v "$PWD":/data cytopia/yamllint /data || true'
        sh 'docker run --rm -i hadolint/hadolint < Dockerfile || true'
      }
    }

    stage('Valider le compose') {
      steps {
        withCredentials([file(credentialsId: 'infra-env-file', variable: 'ENV_FILE')]) {
          sh 'docker compose --env-file "$ENV_FILE" config -q'
        }
      }
    }

    stage('Scan sécurité') {
      steps {
        sh 'docker run --rm -v "$PWD":/src aquasec/trivy config /src --exit-code 0 --severity HIGH,CRITICAL'
      }
    }

    stage('Déploiement') {
      when { branch 'main' }
      steps {
        withCredentials([file(credentialsId: 'infra-env-file', variable: 'ENV_FILE')]) {
          sshagent(['deploy-ssh-key']) {
            sh '''
              rsync -az --delete --exclude '.git' ./ $DEPLOY_HOST:$DEPLOY_DIR/
              scp "$ENV_FILE" $DEPLOY_HOST:$DEPLOY_DIR/.env
              ssh $DEPLOY_HOST "cd $DEPLOY_DIR && docker compose pull && docker compose up -d --remove-orphans"
            '''
          }
        }
      }
    }

    stage('Vérification') {
      when { branch 'main' }
      steps {
        sshagent(['deploy-ssh-key']) {
          sh '''
            sleep 60
            ssh $DEPLOY_HOST "curl -sf http://localhost:11434/api/tags > /dev/null"
            ssh $DEPLOY_HOST "curl -skf https://localhost:9200 -u admin:\\$INDEXER_PASSWORD > /dev/null || true"
            ssh $DEPLOY_HOST "cd $DEPLOY_DIR && docker compose ps"
          '''
        }
      }
    }
  }

  post {
    failure { echo 'Déploiement échoué, vérifiez les logs.' }
  }
}
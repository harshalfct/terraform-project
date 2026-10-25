pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    string(name: 'GIT_URL', defaultValue: '', description: 'Git repository URL.')
    string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch to deploy.')
    string(name: 'AWS_REGION', defaultValue: 'ap-south-1', description: 'AWS deployment region.')
    string(name: 'TF_STATE_REGION', defaultValue: '', description: 'Optional region of the Terraform state bucket; defaults to AWS_REGION.')
    string(name: 'TF_STATE_BUCKET', defaultValue: '', description: 'Pre-created, encrypted S3 bucket for Terraform state.')
    string(name: 'TF_STATE_KEY', defaultValue: 'application/terraform.tfstate', description: 'State key; use a separate key from Jenkins infrastructure.')
    string(name: 'DATABASE_AMI_ID', defaultValue: '', description: 'Ubuntu 24.04 amd64 AMI with AWS CLI and SSM Agent.')
    string(name: 'SSH_TRUSTED_CIDR', defaultValue: '', description: 'Optional trusted IPv4 CIDR for web-instance SSH.')
    string(name: 'KEY_PAIR_NAME', defaultValue: '', description: 'Optional existing EC2 key pair name.')
  }

  environment {
    AWS_DEFAULT_REGION = "${params.AWS_REGION}"
    AWS_REGION = "${params.AWS_REGION}"
    TF_IN_AUTOMATION = 'true'
    TF_INPUT = 'false'
  }

  stages {
    stage('Checkout source code') {
      steps {
        script {
          if (!params.GIT_URL?.trim()) {
            error('Set GIT_URL to the source repository.')
          }
          if (!params.TF_STATE_BUCKET?.trim()) {
            error('Set TF_STATE_BUCKET to the pre-created Terraform state bucket.')
          }
          if (!params.DATABASE_AMI_ID?.trim()) {
            error('Set DATABASE_AMI_ID to a compatible Ubuntu 24.04 AMI with AWS CLI and SSM Agent.')
          }
        }
        deleteDir()
        checkout([$class: 'GitSCM',
          branches: [[name: "*/${params.GIT_BRANCH}"]],
          userRemoteConfigs: [[url: params.GIT_URL, credentialsId: 'git-readonly']]
        ])
      }
    }

    stage('Install application dependencies and run tests') {
      steps {
        dir('app') {
          sh 'node --version && npm ci && npm test'
        }
      }
    }

    stage('Terraform format check') {
      steps {
        sh 'terraform fmt -check -recursive'
      }
    }

    stage('Terraform initialization') {
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-deploy']]) {
          sh '''
            terraform init -input=false \
              -backend-config="bucket=${TF_STATE_BUCKET}" \
              -backend-config="key=${TF_STATE_KEY}" \
              -backend-config="region=${TF_STATE_REGION:-$AWS_REGION}" \
              -backend-config="encrypt=true" \
              -backend-config="use_lockfile=true"
          '''
        }
      }
    }

    stage('Terraform validation') {
      steps {
        sh 'terraform validate'
      }
    }

    stage('Terraform plan') {
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-deploy']]) {
          sh '''
            export TF_VAR_aws_region="$AWS_REGION"
            export TF_VAR_database_ami_id="$DATABASE_AMI_ID"
            export TF_VAR_ssh_trusted_cidr="$SSH_TRUSTED_CIDR"
            if [ -n "$KEY_PAIR_NAME" ]; then
              export TF_VAR_key_pair_name="$KEY_PAIR_NAME"
            fi
            terraform plan -input=false -out=tfplan
          '''
        }
      }
    }

    stage('Manual approval for infrastructure changes') {
      steps {
        input message: 'Review the Terraform plan in this build before applying infrastructure changes.', ok: 'Apply reviewed plan'
      }
    }

    stage('Terraform apply using reviewed plan') {
      steps {
        lock(resource: "terraform-${params.TF_STATE_BUCKET}-${params.TF_STATE_KEY}") {
          withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-deploy']]) {
            sh 'terraform apply -input=false tfplan'
          }
        }
      }
    }

    stage('Deploy or update the Node.js application') {
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-deploy']]) {
          sh '''
            set -eu
            BUCKET="$(terraform output -raw deployment_bucket)"
            DB_INSTANCE="$(terraform output -raw database_instance_id)"
            WEB_INSTANCE="$(terraform output -raw web_instance_id)"
            SHORT_COMMIT="$(git rev-parse --short=12 HEAD)"
            ARTIFACT_KEY="releases/${BUILD_NUMBER}-${SHORT_COMMIT}.tar.gz"

            bash scripts/ssm-run.sh "$DB_INSTANCE" "sudo /usr/local/sbin/bootstrap-mysql"

            tar -czf app.tar.gz --exclude='.env' --exclude='node_modules' -C app .
            aws s3 cp app.tar.gz "s3://${BUCKET}/${ARTIFACT_KEY}"
            bash scripts/ssm-run.sh "$WEB_INSTANCE" "sudo /usr/local/sbin/deploy-nodeapp ${ARTIFACT_KEY}"
          '''
        }
      }
    }

    stage('Verify application health') {
      steps {
        script {
          env.APPLICATION_URL = sh(script: 'terraform output -raw application_url', returnStdout: true).trim()
        }
        sh '''
          set -eu
          attempt=1
          while [ "$attempt" -le 30 ]; do
            if body="$(curl --fail --silent --show-error --max-time 10 "${APPLICATION_URL}/health" 2>/dev/null)" &&
              printf '%s' "$body" | node -e '
                let input = "";
                process.stdin.on("data", (chunk) => input += chunk);
                process.stdin.on("end", () => {
                  try {
                    const health = JSON.parse(input);
                    process.exit(health.status === "ok" && health.database === "connected" ? 0 : 1);
                  } catch {
                    process.exit(1);
                  }
                });
              '; then
              echo "HTTP health check passed."
              exit 0
            fi
            echo "Health check attempt ${attempt}/30 did not pass."
            sleep 10
            attempt=$((attempt + 1))
          done
          echo "Application health check failed."
          exit 1
        '''
      }
    }

    stage('Display deployment URL and status') {
      steps {
        script {
          echo "Application URL: ${env.APPLICATION_URL}"
          echo 'Deployment status: SUCCESS (HTTP and database health checks passed)'
        }
      }
    }
  }
}

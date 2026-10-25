pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    skipDefaultCheckout(true)
  }

  parameters {
    string(name: 'GIT_URL', defaultValue: '', description: 'Git repository URL.')
    string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch to deploy.')
    string(name: 'AWS_REGION', defaultValue: 'ap-south-1', description: 'AWS region for the application.')
    string(name: 'TF_STATE_REGION', defaultValue: '', description: 'Terraform state bucket region; defaults to AWS_REGION.')
    string(name: 'TF_STATE_BUCKET', defaultValue: '', description: 'Pre-created, encrypted S3 bucket for Terraform state.')
    string(name: 'TF_STATE_KEY', defaultValue: 'application/terraform.tfstate', description: 'Unique Terraform state key for this environment.')
    string(name: 'DATABASE_AMI_ID', defaultValue: '', description: 'Ubuntu 24.04 amd64 AMI with AWS CLI, Python 3, OpenSSL, and SSM Agent.')
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
    stage('Checkout and check inputs') {
      steps {
        script {
          if (!params.GIT_URL?.trim()) {
            error('Set GIT_URL to the source repository.')
          }
          if (!params.GIT_BRANCH?.trim()) {
            error('Set GIT_BRANCH to the source branch.')
          }
          if (!params.AWS_REGION?.trim()) {
            error('Set AWS_REGION to the application deployment region.')
          }
          if (!params.TF_STATE_BUCKET?.trim()) {
            error('Set TF_STATE_BUCKET to the pre-created Terraform state bucket.')
          }
          if (!params.TF_STATE_KEY?.trim()) {
            error('Set TF_STATE_KEY to a unique state key for this environment.')
          }
          if (!params.DATABASE_AMI_ID?.trim()) {
            error('Set DATABASE_AMI_ID to a compatible Ubuntu 24.04 amd64 AMI.')
          }
        }

        echo 'deleteDir() clears old workspace files so this build starts clean.'
        deleteDir()
        echo 'checkout downloads the selected branch using the read-only Git credential.'
        checkout([$class: 'GitSCM',
          branches: [[name: "*/${params.GIT_BRANCH}"]],
          userRemoteConfigs: [[url: params.GIT_URL, credentialsId: 'git-readonly']]
        ])
      }
    }

    stage('Test the application') {
      steps {
        dir('app') {
          echo 'node --version and the next check ensure the agent uses Node.js 22.'
          sh 'node --version'
          sh '''
            NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
            test "$NODE_MAJOR" = "22"
          '''
          echo 'npm ci installs the exact locked dependencies; npm test runs the application tests.'
          sh 'npm ci'
          sh 'npm test'
        }
      }
    }

    stage('Check and initialize Terraform') {
      steps {
        echo 'terraform fmt -check -recursive fails if any Terraform file is not formatted.'
        sh 'terraform fmt -check -recursive'

        echo 'terraform init configures the remote S3 state and native state locking.'
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

        echo 'terraform validate checks Terraform syntax, modules, and required arguments.'
        sh 'terraform validate'
      }
    }

    stage('Plan and approve infrastructure') {
      steps {
        echo 'terraform plan previews changes and saves the exact reviewed plan as tfplan.'
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

        echo 'Approval is required before Terraform is allowed to change AWS infrastructure.'
        input message: 'Review the Terraform plan in this build before applying infrastructure changes.', ok: 'Apply reviewed plan'
      }
    }

    stage('Apply reviewed infrastructure plan') {
      steps {
        echo 'terraform apply executes only the saved plan after approval; the state lock prevents concurrent applies.'
        lock(resource: "terraform-${params.TF_STATE_BUCKET}-${params.TF_STATE_KEY}") {
          withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-deploy']]) {
            sh 'terraform apply -input=false tfplan'
          }
        }
      }
    }

    stage('Deploy application') {
      steps {
        echo 'SSM bootstraps the private MySQL instance without opening public SSH access.'
        echo 'tar packages the app without local secrets or node_modules; aws s3 cp uploads the release archive.'
        echo 'SSM runs the web-instance deployment script, which downloads the archive and restarts the app.'
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

    stage('Verify and report deployment') {
      steps {
        echo 'terraform output reads the public application URL created by the reviewed deployment.'
        script {
          env.APPLICATION_URL = sh(script: 'terraform output -raw application_url', returnStdout: true).trim()
        }

        echo 'curl retries /health for up to five minutes; HTTP 200 means the app and MySQL check passed.'
        sh '''
          set -eu
          attempt=1
          while [ "$attempt" -le 30 ]; do
            if curl --fail --silent --show-error --max-time 10 \
              --output /dev/null "${APPLICATION_URL}/health"; then
              echo "Application and database health check passed."
              exit 0
            fi
            echo "Health check attempt ${attempt}/30 did not pass."
            sleep 10
            attempt=$((attempt + 1))
          done
          echo "Application health check failed."
          exit 1
        '''

        echo 'The URL is displayed only after the application and database health check passes.'
        echo "Application URL: ${env.APPLICATION_URL}"
      }
    }
  }
}

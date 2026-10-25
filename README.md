# Three-tier Node.js and MySQL deployment

This workspace contains a Terraform-managed AWS application stack and a Jenkins deployment pipeline.

## Architecture

- One VPC in `ap-south-1` with exactly two subnets: a public web/NAT subnet in `ap-south-1a` and a private database subnet in `ap-south-1b`.
- The public subnet hosts the web EC2 instance and NAT Gateway. Nginx accepts HTTP on port 80 and proxies to Express on `127.0.0.1:3000`; the Node port is not exposed by the security group.
- The private subnet contains only the MySQL EC2 instance. It has no public IP, and MySQL TCP 3306 is allowed only from the web security group.
- An Internet Gateway provides public subnet internet access. One NAT Gateway in `ap-south-1a` provides private subnet egress for MySQL package installation and updates. Traffic from the private subnet in `ap-south-1b` crosses Availability Zones and incurs NAT and cross-AZ charges; the single NAT Gateway is not highly available.
- Private interface endpoints provide the DB instance access to Secrets Manager and Systems Manager. These endpoints also incur AWS charges.
- Jenkins stays outside this application Terraform state and is not created, updated, or destroyed by this pipeline. `modules/jenkins-server/` documents that state boundary.

The initial deployment uses HTTP. HTTPS requires a domain and certificate configuration and is intentionally not included.

## Project structure

```text
.
├── Jenkinsfile                 # CI/CD pipeline and deployment stages
├── .gitignore                  # Ignores local secrets, memory, and generated files
├── terraform.tf                # Terraform version, AWS provider, and S3 backend
├── provider.tf                 # AWS provider and Ubuntu web AMI lookup
├── main.tf                     # Root resources and module wiring
├── variable.tf                 # Root infrastructure inputs and validation
├── output.tf                   # Deployment and infrastructure outputs
├── .terraform.lock.hcl         # Locked Terraform provider selections
├── app/
│   ├── package.json             # Runtime dependencies and npm scripts
│   ├── package-lock.json        # Reproducible npm dependency lock
│   ├── server.js                # Express API, health checks, and auth sessions
│   ├── server.test.js
│   ├── public/
│   │   ├── index.html           # Application and database status
│   │   ├── login.html
│   │   └── register.html
│   └── private/
│       └── dashboard.html       # Authenticated dashboard
├── modules/
│   ├── networking/
│   │   ├── main.tf              # VPC, two subnets, NAT, endpoints, routes, and security groups
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── web-server/
│   │   ├── main.tf              # Web EC2 and IAM
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── templates/
│   │       └── web-bootstrap.sh.tftpl
│   ├── database-server/
│   │   ├── main.tf              # Database EC2 and IAM
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── templates/
│   │       └── mysql-bootstrap.sh.tftpl
│   └── jenkins-server/
│       └── README.md            # Separate Jenkins state boundary
├── scripts/
│   └── ssm-run.sh
```

The local `.terraform/` and `app/node_modules/` directories are generated dependencies and are not part of the project source structure.

## Application

`app/` contains the Express application, a simple status page, and automated tests:

- `GET /` displays application and MySQL connectivity status.
- `GET /health` checks the database and returns HTTP 503 while it is unavailable.
- `GET /users` reads database-backed rows using a parameterized query and validates its optional row limit.
- `GET /register` serves an account registration form. `POST /register` validates name, email, and password, normalizes email, hashes the password with bcrypt, and inserts the account with a parameterized query. Duplicate emails return HTTP 409.
- `GET /login` serves the login form. `POST /login` verifies the bcrypt password and issues an opaque, random, HttpOnly/SameSite cookie. Only its SHA-256 hash is stored in MySQL. `GET /dashboard` requires a live session; `POST /logout` revokes it.
- Database connection values are read from process environment variables. Errors returned to clients do not include credentials or stack traces.
- Node.js 22 LTS, Git, the MySQL client, and PM2 are installed on the web instance. PM2 runs under a systemd service; Nginx proxies to the loopback listener.
- The application MySQL role has `SELECT` and `INSERT` on `users`; the idempotent DB bootstrap adds a nullable `password_hash` column for existing databases. The users API does not return password hashes.
- The bootstrap creates an `auth_sessions` table and grants only SELECT/INSERT/DELETE on that table for login, session lookup, and logout. Production cookies include `Secure`; local HTTP cookies do not.

Run the local test suite with Node.js 22 (the API tests use a mocked MySQL pool and do not require AWS or a running MySQL server):

```sh
cd app
npm ci
npm test
```

To run the application against local MySQL, create a local-only `app/.env` containing `HOST=127.0.0.1`, `PORT=3000`, `DB_HOST`, `DB_PORT=3306`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`. Never commit `.env` or credentials. Ensure the database has the `users` table described above, then start using Node.js 22:

```sh
cd app
npm ci
node --env-file=.env server.js
```

Visit `http://127.0.0.1:3000/`, `/register`, `/login`, and `/health`. The app needs an `auth_sessions` table for login; the Terraform bootstrap creates it automatically in deployed environments. Locally, create it once with a foreign key from `user_id` to `users.id`, and do not run destructive database initialization during app updates. Without working DB settings, the app reports the database as unavailable and `/health` returns HTTP 503.

## Private MySQL installation

Provide an Ubuntu 24.04 amd64 database AMI with AWS CLI, Python 3, OpenSSL, and a working SSM Agent. Set its ID in `DATABASE_AMI_ID`. If MySQL is not already installed, the `/usr/local/sbin/bootstrap-mysql` script uses the NAT Gateway to run `apt-get update` and install `mysql-server`. The instance remains private with no public IP; its security group allows outbound HTTP/HTTPS for package repositories and limits MySQL ingress to the web security group.

The bootstrap starts MySQL, binds it to the instance's private network interfaces, creates the database and least-privilege application account if absent, and idempotently creates `users` and `auth_sessions`. The pipeline invokes this script using SSM before deploying the app.

The DB bootstrap generates a random password only when the Secrets Manager secret has no version, writes it to Secrets Manager, and reuses that value on subsequent runs. The password is not supplied as a Terraform variable, embedded in source, or printed by the pipeline. The DB EC2 role can read/write only this secret; the web EC2 role can read that secret and deployment objects. MySQL application credentials are not stored in Terraform state.

## Jenkins prerequisites

Configure the Jenkins agent with:

- Terraform 1.10 or later, AWS CLI, Node.js 22/npm, Python 3, `curl`, `tar`, and Bash.
- Pipeline, Git, Credentials Binding, AWS Credentials Binding, and Lockable Resources plugins.
- Jenkins credential ID `aws-deploy` of the AWS credentials type, scoped to the target account and region. The role/user needs the Terraform resource permissions, narrowly scoped `iam:PassRole`, access to the state and deployment buckets, and SSM send/read-command permissions.
- Jenkins Git credential ID `git-readonly` with read-only access to the application repository.
- A pre-created S3 state bucket with encryption and versioning. Each application environment must use its own state key. The S3 backend uses native lock files; Jenkins also serializes applies for a state key.
- A compatible Ubuntu 24.04 amd64 database AMI with AWS CLI, Python 3, OpenSSL, and SSM Agent. MySQL may be preinstalled or installed through the NAT Gateway.

Keep the Jenkins server and its own state separate. The application job must not run `terraform destroy`; the pipeline contains no destroy stage. The Terraform database instance, secret, and artifact bucket have deletion protection.

## Deployment

Create a Jenkins Pipeline job using this repository's `Jenkinsfile`. Supply:

- `GIT_URL` and `GIT_BRANCH`; checkout uses the Jenkins `git-readonly` credential.
- `AWS_REGION`, `TF_STATE_BUCKET`, and a unique `TF_STATE_KEY`.
- `TF_STATE_REGION` only when the state bucket is in a different AWS region; otherwise it defaults to `AWS_REGION`.
- `DATABASE_AMI_ID` for the compatible Ubuntu 24.04 amd64 database AMI.
- Optional `SSH_TRUSTED_CIDR` and `KEY_PAIR_NAME`. SSH ingress is disabled when no trusted CIDR is set.

The job checks out source, installs app dependencies, and runs tests before checking Terraform formatting, initializing and validating Terraform, creating a saved plan, waiting for manual approval, and applying that reviewed plan. After apply, it bootstraps the private database through SSM, uploads a versioned app archive to S3, deploys it through SSM, and retries the public `/health` check. It fails if the app or database health check does not pass. It prints the URL as successful only after a passing HTTP health check.

Application dependencies and tests run immediately after checkout, before Terraform plan or apply. A failed application test therefore stops the job before any infrastructure changes. This repository has not been connected to a Jenkins server or AWS account; run Jenkins only after local tests pass and the required deployment prerequisites are configured. The pipeline pauses for explicit approval before applying its reviewed Terraform plan.

Manual Terraform validation (requires Terraform and a pre-existing backend bucket):

```sh
terraform fmt -check -recursive
terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=application/terraform.tfstate" \
  -backend-config="region=ap-south-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform validate
terraform plan
```

Do not run `terraform apply` outside the reviewed Jenkins workflow unless the operator explicitly approves it. No AWS resources have been provisioned by this change. The application URL and infrastructure outputs will be available from Terraform only after an authorized deployment; the app must not be considered live until Jenkins reports a successful health check.

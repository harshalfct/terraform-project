# Jenkins server and pipeline setup

This guide explains how to create a Jenkins server for this repository, configure
the required tools and credentials, create the pipeline job, and run a deployment.
It is written for an AWS-hosted Ubuntu Jenkins server and the pipeline in
[`Jenkinsfile`](./Jenkinsfile).

The application pipeline manages the application VPC, database and web instances,
and related AWS resources. **It does not create or manage its own Jenkins server.**
Keep the Jenkins server and its Terraform state in a separate stack and state
key. Do not add the Jenkins server to the application pipeline.

## 1. What you need before starting

Have the following ready:

- An AWS account and a deployment region, such as `ap-south-1`.
- Permission to create an EC2 instance, security group, IAM identity/permissions,
  and an S3 bucket.
- A source-code repository containing this `Jenkinsfile`, the Terraform files,
  `app/`, and `scripts/`.
- A Git credential that can read the repository.
- An encrypted, versioned S3 bucket for Terraform state. The bucket must exist
  before the pipeline runs.
- An Ubuntu 24.04 amd64 database AMI in the application region. It must include
  AWS CLI, Python 3, OpenSSL, and a running Systems Manager (SSM) Agent.
- An AWS deployment credential for Jenkins with permission to create and manage
  the application's Terraform resources, read/write the state bucket, upload
  deployment artifacts, and invoke/read SSM commands.

The pipeline deploys HTTP on port 80; it does not configure HTTPS or a domain.
NAT Gateways and interface VPC endpoints incur AWS charges. Review the expected
costs before approving the Terraform plan.

## 2. Create the Jenkins EC2 server

For a small, single-controller installation, start with an Ubuntu 24.04 amd64 EC2
instance with at least 2 vCPUs, 4 GiB RAM, and an encrypted 30 GiB or larger gp3
root volume. A larger volume may be needed as builds and plugin data accumulate.
The pipeline uses `agent any`, so in this basic configuration jobs run on the
Jenkins controller itself. For a production installation, use a separate,
restricted build agent instead of running builds on the controller.

### 2.1 Create a security group

Create a security group for the Jenkins host. Allow inbound traffic only from
trusted administrator addresses:

| Protocol | Port | Source | Purpose |
|---|---:|---|---|
| TCP | 22 | Your administrator IP/CIDR only | SSH administration |
| TCP | 8080 | Your administrator/VPN IP/CIDR only | Jenkins web interface |

Do not expose SSH or Jenkins port 8080 to `0.0.0.0/0`. Do not add inbound
application ports 80, 3000, or 3306 to the Jenkins server. Allow required
outbound internet access for package installation, Git, Jenkins updates,
Terraform provider downloads, Node.js dependencies, and AWS APIs.

For stronger isolation, put Jenkins in a private subnet and access it through a
VPN or a managed administrative tunnel. If you use a public IP for initial
setup, restrict the security group to your current trusted IP and remove public
access when it is no longer needed.

### 2.2 Launch the instance

In the AWS EC2 console:

1. Select **Launch instance** and choose **Ubuntu Server 24.04 LTS, 64-bit
   x86**.
2. Choose the instance size and encrypted gp3 volume described above.
3. Select the Jenkins security group.
4. Create or select an EC2 key pair if you need SSH administration. Store the
   private key securely; AWS does not let you download it again.
5. Require IMDSv2 for instance metadata.
6. Launch the instance and note its instance ID and private/public address.

If SSH is enabled, connect only from an allowed administrator address:

```sh
ssh -i PATH_TO_PRIVATE_KEY ubuntu@JENKINS_SERVER_ADDRESS
```

Replace the placeholders with your local key path and the server's address.
Never copy the private key into the repository or Jenkins credentials used by
the application pipeline.

### 2.3 Install Jenkins LTS

Connect to the instance and install Java 21 and Jenkins LTS from the official
Jenkins Debian package repository:

```sh
set -e
sudo apt-get update
sudo apt-get install -y ca-certificates curl fontconfig openjdk-21-jre
java -version

sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update
sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins
sudo systemctl status jenkins --no-pager
```

`set -e` stops this block at the first failed command. Do not continue to the
`systemctl` commands unless `apt-get install jenkins` succeeds.

If APT reports **“Package 'jenkins' has no installation candidate”**, the
Jenkins package repository was not successfully added or its package index was
not downloaded. The later **“jenkins.service could not be found”** message is
expected because the package was never installed. Repair and verify the APT
repository before trying to start the service:

```sh
sudo apt update
sudo apt install fontconfig openjdk-21-jre
java -version

sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins
```


### 2.4 Complete the first-time setup

1. Open `http://JENKINS_SERVER_ADDRESS:8080` from an allowed network.
2. Read the initial administrator password on the server:

   ```sh
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```

3. Paste it into the unlock screen.
4. Select **Install suggested plugins**.
5. Create a named administrator account with a strong, unique password.
6. Confirm the Jenkins URL, using a private or HTTPS URL if one is configured.
7. After setup, remove inbound port 8080 from any source that does not need
   access. Prefer an HTTPS reverse proxy or private network access for ongoing
   use rather than sending administrator credentials over public HTTP.

Do not leave Jenkins using the initial setup password or a shared administrator
account.

## 3. Install build tools on the Jenkins executor

The pipeline runs Unix `sh` commands and therefore needs a Linux executor. The
following commands install the project tools on the Ubuntu controller. Run them
on the Jenkins EC2 host. For a separate build agent, install these tools on that
agent instead and configure the Jenkins node to accept this pipeline.

### 3.1 Install general tools

```sh
sudo apt-get update
sudo apt-get install -y bash ca-certificates curl git gnupg python3 tar unzip
```

These provide shell execution, Git checkout, archive creation, Python for the
SSM helper, and package-repository support.

### 3.2 Install Node.js 22 and npm

```sh
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
npm --version
```

The pipeline explicitly fails unless the Node.js major version is `22`.

### 3.3 Install Terraform

Install Terraform from HashiCorp's signed apt repository:

```sh
wget -O- https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform
terraform version
```

This project requires Terraform 1.10 or newer and AWS provider 5.x. The provider
version is constrained and locked by the repository.

### 3.4 Install AWS CLI v2

```sh
cd /tmp
curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
unzip -q awscliv2.zip
sudo ./aws/install
aws --version
```

This command assumes an x86_64 Jenkins instance. Use the matching official AWS
CLI installer if the server has a different CPU architecture.

## 4. Install the Jenkins plugins

In Jenkins, open **Manage Jenkins → Plugins → Available plugins**, search for
and install these plugins:

| Plugin | Why this pipeline needs it |
|---|---|
| Pipeline | Declarative Pipeline and pipeline stages |
| Git | Git SCM checkout |
| Git client | Git operations used by the Git plugin |
| Credentials Binding | `withCredentials` support |
| AWS Credentials | AWS credential type and `AmazonWebServicesCredentialsBinding` used by the pipeline |
| Lockable Resources | The `lock` step used to serialize Terraform applies |
| Pipeline: Input Step | Manual approval step; usually installed as a Pipeline dependency |

Restart Jenkins when prompted. Confirm the plugins are installed under
**Manage Jenkins → Plugins → Installed plugins**.

The Jenkins controller and executor also need internet access to fetch Git
content, Terraform providers, and npm packages. If outbound internet is
restricted, configure approved internal mirrors before running a build.

## 5. Create the S3 Terraform state bucket

Create this bucket before the pipeline. Use an S3 bucket in the deployment
account and select a unique bucket name. In the S3 console:

1. Create a general-purpose bucket in the desired state region.
2. Keep **Block all public access** enabled.
3. Enable bucket versioning.
4. Enable default server-side encryption (SSE-S3 or an approved KMS key).
5. Keep Object Ownership set to **Bucket owner enforced**.
6. Do not enable public website hosting.
7. Restrict bucket access to the Jenkins AWS identity and authorized operators.

The pipeline's `terraform init` enables state encryption and native S3 lock
files. The AWS identity needs access to the bucket and to the state object and
its `.tflock` object. In particular, it needs permission to list the bucket and
read/write/delete the relevant state and lock objects. Use a unique state key
per application environment, for example:

```text
application/terraform.tfstate
```

Do not reuse a Jenkins server's state key or another application's key.
Versioning helps recover earlier state versions; it does not replace access
control or backups.

## 6. Create the AWS permissions and Jenkins credential

The pipeline expects an AWS Credentials plugin credential with the exact ID
`aws-deploy`. It uses this credential for Terraform and AWS CLI operations.
Create a dedicated IAM identity for the pipeline rather than using an
administrator's personal credentials.

### 6.1 Required permission areas

Create and review a dedicated IAM policy for the application pipeline. It must
allow the actions required to:

- Discover the selected region's available Availability Zones and Ubuntu AMIs.
- Create, describe, update, and delete the application's VPC, subnets, routes,
  internet/NAT gateways, Elastic IP, security groups, interface endpoints, and
  EC2 instances.
- Create and manage the application's IAM roles, instance profiles, policies,
  and policy attachments. Limit `iam:PassRole` to only the application EC2 roles
  that Terraform creates.
- Create and manage the Secrets Manager secret metadata used by the database.
- Create and manage the deployment artifact bucket and its versioning,
  encryption, and public-access-block configuration.
- Read and write the Terraform state and S3 lock file in the state bucket.
- Upload release archives to the deployment bucket.
- Send SSM commands to the web and database instances and read command
  invocation status/results.

Scope permissions to the application region, account, state bucket, and
deployment resource names wherever the AWS service supports resource-level
permissions. Some resource-creation and discovery actions require `"Resource":
"*"`; restrict them by region and applicable request conditions where possible.
Do not attach `AdministratorAccess` as a shortcut. Validate the policy in a
non-production account and refine any `AccessDenied` messages by adding only
the missing required action.

The EC2 web and database instances have their own instance roles for runtime
access; those are distinct from the Jenkins deployment identity. The Jenkins
credential is not copied onto the application instances.

### 6.2 Create the AWS credential in Jenkins

For this pipeline, the AWS Credentials binding expects an AWS Credentials plugin
entry:

1. In AWS IAM, create a dedicated deployment IAM user or another supported,
   controlled credential source. If using an IAM user, enable programmatic
   access only and attach the reviewed policy from the previous section.
2. Create an access key for that identity and securely retain the access key ID
   and secret access key. Never paste either value into source code, a
   `Jenkinsfile`, a build parameter, or a console command that will be saved in
   shell history.
3. In Jenkins, open **Manage Jenkins → Credentials → System → Global
   credentials (unrestricted) → Add Credentials**.
4. Set **Kind** to **AWS Credentials**.
5. Enter the access key ID and secret access key.
6. Set **ID** to exactly `aws-deploy`.
7. Add a description such as `Scoped Terraform and deployment permissions`.
8. Save the credential.

If **AWS Credentials** is not available under **Kind**, check that the AWS
Credentials plugin is installed and Jenkins was restarted. Do not substitute a
plain username/password credential; the pipeline requests the AWS-specific
binding.

Protect Jenkins administrator access because anyone who can modify or run this
pipeline may be able to use its AWS permissions. Rotate the AWS key periodically
and immediately after suspected exposure. The pipeline's AWS credentials are
only bound for AWS/Terraform steps; do not print environment variables or enable
shell tracing (`set -x`).

## 7. Create the read-only Git credential

The `checkout` step in the pipeline expects the Jenkins credential ID
`git-readonly`.

For a private repository over HTTPS, create a repository access token limited
to read-only source/content access. In Jenkins:

1. Open **Manage Jenkins → Credentials → System → Global credentials
   (unrestricted) → Add Credentials**.
2. Set **Kind** to **Username with password**.
3. Set **Username** to the Git provider username or token username required by
   your provider.
4. Set **Password** to the read-only access token. Do not put the token in the
   repository URL.
5. Set **ID** to exactly `git-readonly`.
6. Add a description such as `Read-only source checkout`.
7. Save the credential.

For SSH checkout instead, use **SSH Username with private key** and assign the
same ID, after confirming that the Jenkins Git plugin can use that key for the
repository. Do not store the Git server's private key in the repository.

For a public repository, the checkout may not need authentication, but this
pipeline still refers to `git-readonly`. Configure the credential or update the
Jenkinsfile checkout configuration intentionally before running the job.

## 8. Find the database AMI ID

`DATABASE_AMI_ID` must be an Ubuntu 24.04 amd64 AMI in the application region
with AWS CLI, Python 3, OpenSSL, and SSM Agent. MySQL may be preinstalled, or
the pipeline bootstrap installs it through the application's NAT Gateway.

You can search from an AWS CLI session with permission to describe images:

```sh
aws ec2 describe-images \
  --region ap-south-1 \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
    "Name=architecture,Values=x86_64" \
    "Name=virtualization-type,Values=hvm" \
  --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' \
  --output text
```

Replace `ap-south-1` with the intended `AWS_REGION`. Verify the resulting AMI
owner, architecture, operating system, and SSM Agent before using it. AMI IDs
are region-specific; an ID from one region may not exist in another.

## 9. Create the Pipeline job

### 9.1 Add a pipeline job

1. From the Jenkins dashboard, select **New Item**.
2. Give the job a descriptive name, for example `three-tier-application`.
3. Select **Pipeline** and choose **OK**.
4. Under **Build Triggers**, leave automatic triggers disabled for the first
   deployment. Add a webhook or polling only after testing and deciding which
   repository changes are authorized to deploy.
5. Under **Pipeline**, choose **Pipeline script from SCM**.
6. Set **SCM** to **Git**.
7. Set **Repository URL** to the clone URL for this repository.
8. Set **Credentials** to `git-readonly` for a private repository.
9. Set **Branches to build** to the branch containing the pipeline, usually
   `*/main`.
10. Set **Script Path** to `Jenkinsfile`.
11. Save the job.

The job's SCM checkout loads the Jenkinsfile. The separate `GIT_URL` and
`GIT_BRANCH` build parameters are used by the pipeline's own checkout stage to
select the source revision it will test and deploy. Use the same repository URL
and branch in both places unless you intentionally need a different deployment
source.

### 9.2 Initial parameter discovery

Jenkins reads declarative pipeline parameters from the Jenkinsfile. On the first
job run, the parameter form may not be available until Jenkins has loaded that
Jenkinsfile once. If the initial run stops because required parameters are
empty, wait for the job configuration to update, select **Build with
Parameters**, enter the values below, and run it again.

### 9.3 Set build parameters

Use **Build with Parameters** and enter:

| Parameter | Required? | Example / guidance |
|---|---|---|
| `GIT_URL` | Yes | Repository clone URL. For example, `https://github.com/ORG/REPOSITORY.git`. |
| `GIT_BRANCH` | Yes | Branch to deploy, for example `main`. Do not include `*/`. |
| `AWS_REGION` | Yes | Application region, for example `ap-south-1`. This selects the application resources and Availability Zones. |
| `TF_STATE_REGION` | No | State bucket region only if it differs from `AWS_REGION`; leave blank otherwise. |
| `TF_STATE_BUCKET` | Yes | Name of the pre-created private, versioned, encrypted state bucket. |
| `TF_STATE_KEY` | Yes | Unique state object path, for example `application/terraform.tfstate`. Use a distinct key for each environment. |
| `DATABASE_AMI_ID` | Yes | The compatible Ubuntu 24.04 amd64 AMI ID from the previous section, such as `ami-0123456789abcdef0`. Use the real ID for your account/region. |
| `SSH_TRUSTED_CIDR` | No | Trusted IPv4 CIDR for SSH to the web server. Leave blank to disable SSH ingress. Never use `0.0.0.0/0`. |
| `KEY_PAIR_NAME` | No | Existing EC2 key pair name for web-server SSH. Leave blank if SSH access is not needed. |

The region, AMI, state bucket, state key, and Git values must all match the
resources and source branch you intend to deploy. The AWS access key and Git
token are Jenkins credentials, **not** build parameters.

## 10. Run the pipeline and approve the plan

Select **Build with Parameters**, confirm the values, and start the build. Open
the build's **Console Output** to follow the stages.

| Stage | What happens |
|---|---|
| Checkout and check inputs | Checks required values, clears old workspace files, and checks out the selected branch using `git-readonly`. |
| Test the application | Requires Node.js 22, runs `npm ci` from `app/`, and runs `npm test`. A failure stops the pipeline before infrastructure changes. |
| Check and initialize Terraform | Checks formatting, initializes Terraform with the encrypted S3 backend and lock file, and validates the configuration. |
| Plan and approve infrastructure | Passes `AWS_REGION`, `DATABASE_AMI_ID`, and optional SSH settings to Terraform, saves a plan, and pauses for human approval. |
| Apply reviewed infrastructure plan | Applies the saved plan only after approval, using a state-specific Jenkins lock. |
| Deploy application | Runs DB bootstrap over SSM, packages the application without `.env` or `node_modules`, uploads it to the Terraform-created artifact bucket, then deploys to the web instance over SSM. |
| Verify and report deployment | Retries the public `/health` request for up to five minutes and prints the application URL only after HTTP 200. The endpoint returns success only when the database check passes. |

When the build pauses at **Plan and approve infrastructure**, review the build
log and Terraform plan before selecting **Proceed**. The `input` step is an
infrastructure change approval, not merely a test confirmation. Do not approve
unexpected replacements, deletions, or changes to resources you do not intend
to manage.

The pipeline contains no `terraform destroy` stage. Do not remove Terraform
deletion-protection settings or use a different state key to bypass protections.

## 11. Confirm a successful deployment

At the end of a successful build, Jenkins prints an application URL similar to
`http://PUBLIC_WEB_SERVER_DNS`. Open it in a browser and confirm the page loads.
The pipeline also checks `/health`, which must report the application and
database as connected before the build succeeds.

If the build fails:

1. Open **Console Output** and find the first failed stage and command.
2. For checkout errors, verify `GIT_URL`, `GIT_BRANCH`, and `git-readonly`.
3. For Node errors, verify the executor has Node.js 22 and network access to npm.
4. For Terraform backend errors, verify the state bucket name, state key,
   `TF_STATE_REGION`, and S3 permissions.
5. For AWS `AccessDenied`, identify the denied action and resource in the error;
   add only the required permission after reviewing its scope.
6. For SSM timeouts, confirm the target instances are online in Systems Manager,
   have their instance profiles, and can reach required AWS services.
7. For health-check failures, inspect the web and database bootstrap logs through
   your approved Systems Manager workflow and verify the database instance is
   ready before retrying.

Do not paste credentials, secret values, private keys, or unredacted sensitive
logs into issues or chat when asking for help.

## 12. Operational security and maintenance

- Keep Jenkins, Java, plugins, Ubuntu packages, Node.js, Terraform, and AWS CLI
  updated. Schedule maintenance and backups.
- Restrict who can administer Jenkins, change the job, edit the Jenkinsfile,
  start a build, and approve the Terraform `input` step.
- Treat build logs and workspaces as sensitive. Do not enable shell tracing or
  print credential environment variables.
- Keep Jenkins HTTP access private or put Jenkins behind HTTPS. Do not expose
  port 8080 to the public internet.
- Back up Jenkins configuration and credentials securely. Jenkins credentials
  are encrypted using the controller's local key material; a backup must
  protect both configuration and secret material.
- Rotate the Git token and AWS access key, then update the matching Jenkins
  credential without changing its ID.
- Keep Jenkins server Terraform, if used, in its own repository or state. The
  application Terraform state must never be used to recreate the CI server.
- Review AWS costs for EC2, NAT Gateway, interface endpoints, EBS, S3, and data
  transfer. Delete application resources only through a separately reviewed,
  authorized lifecycle process.

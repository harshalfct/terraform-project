# Next steps

1. Local end-to-end verification against `tfdb` is complete; app remains running at `http://127.0.0.1:3000`. Preserve `app/.env` as local-only, ignored configuration.
2. Before cloud deployment, configure Jenkins credentials/plugins and a Jenkins agent with Terraform, AWS CLI, Node.js 22/npm, Python 3, `curl`, `tar`, and Bash.
3. Provide an Ubuntu 24.04 amd64 database AMI with AWS CLI/SSM Agent, plus either preinstalled MySQL or the matching offline MySQL package bundle.
4. Pre-create the encrypted/versioned Terraform S3 backend bucket, configure unique state key and AWS region, and review AWS permissions and endpoint costs.
5. Run the Jenkins pipeline, review its Terraform plan, and explicitly approve apply. Do not destroy infrastructure.
6. Record an AWS application URL only after the pipeline's public HTTP `/health` check passes. AWS has not been provisioned.
7. Add HTTPS only after a domain and certificate configuration are supplied.

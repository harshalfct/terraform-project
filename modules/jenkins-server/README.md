# Jenkins server state boundary

The Jenkins server is intentionally not instantiated by this application's Terraform root. The application pipeline manages only the VPC, web/database instances, supporting IAM, Secrets Manager secret metadata, S3 artifacts, and the necessary VPC endpoints. Keep the Jenkins host and its state in its existing independently managed stack so an application plan/apply cannot replace or destroy the CI server.

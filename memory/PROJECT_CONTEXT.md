# Project context

- The selected workspace `D:\Three tier\terraform-project` was empty at the start of this task. No prior project source or memory documents were available to preserve.
- This project now scaffolds an AWS Terraform and Jenkins workflow for a three-tier Node.js/Express and MySQL application.
- Jenkins remains external to the application Terraform state. Its host is not provisioned by the application pipeline.
- The web tier uses Node.js 22 LTS, Git, MySQL client, Express, MySQL2, PM2 under systemd, and Nginx. Public traffic is HTTP on port 80; the Node listener is `127.0.0.1:3000`.
- `/register` serves account registration; `POST /register` validates data, hashes passwords with bcrypt, and executes parameterized INSERT. DB bootstrap adds `password_hash` and grants the application SELECT/INSERT on `users`.
- `/login` verifies bcrypt passwords and issues an opaque, HttpOnly session cookie; only a SHA-256 token hash is persisted in `auth_sessions`. `/dashboard` requires a valid session, `/api/me` returns the current account, and `/logout` revokes the session.
- Local verification passed against MySQL `tfdb`; the app is running at `http://127.0.0.1:3000` with `/health` returning HTTP 200. The ignored `app/.env` contains local configuration only and is never copied into deployment artifacts.
- The MySQL EC2 instance is private, has no public IP or internet default route, and accepts TCP 3306 only from the web security group.
- The DB AMI is a required input: Ubuntu 24.04 amd64 with AWS CLI, Python 3, OpenSSL, and SSM Agent. If MySQL is not included, Jenkins supplies a matching offline MySQL/AWS CLI package bundle through the private S3 endpoint.
- DB credentials are generated during MySQL bootstrap and stored in AWS Secrets Manager. No password or access key belongs in project or memory files.
- Deployment source is versioned in a private S3 artifact bucket. Jenkins checks out Git with a Jenkins credential and deploys through SSM.

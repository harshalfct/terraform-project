# Architecture

- One VPC, one public web subnet, and one private database subnet in one Availability Zone.
- Internet Gateway route applies only to the public subnet. No NAT Gateway, load balancer, or additional subnet is created.
- Web EC2: Ubuntu 24.04, Nginx:80, Express/Node.js 22 LTS on loopback port 3000, MySQL client, PM2 runtime managed by systemd, AWS instance profile for SSM, Secrets Manager read, and deployment-object read.
- Database EC2: supplied Ubuntu 24.04 amd64 AMI with AWS CLI, Python 3, OpenSSL, and SSM Agent; no public IPv4; MySQL TCP 3306. Its security group allows 3306 only from the web security group.
- Private DB egress uses an S3 gateway endpoint and interface endpoints for Secrets Manager and SSM messaging/control. These endpoints allow package artifact delivery, secret retrieval, and SSM deployment without public internet egress; interface endpoints have AWS hourly/data charges.
- Nginx proxies HTTP to `127.0.0.1:3000`. `/health` reports degraded while MySQL is unavailable. `/users` executes a parameterized `LIMIT ?` query. `/register` serves an account form; POST validates inputs and uses bcrypt plus parameterized SQL insertion. `/login` issues an HttpOnly opaque session cookie; `/dashboard` requires authentication; `/logout` revokes the database-backed session.
- `modules/database-server/templates/mysql-bootstrap.sh.tftpl` installs the idempotent `/usr/local/sbin/bootstrap-mysql` script. It obtains an offline package bundle through S3 if the AMI lacks MySQL, starts MySQL, creates schema/account without dropping data, adds `password_hash` and `auth_sessions` for existing schemas, grants only required table-level privileges, and creates or reuses the Secrets Manager password.
- `modules/web-server/templates/web-bootstrap.sh.tftpl` installs Node.js 22, Git, MySQL client, Nginx, AWS CLI, and PM2; writes Nginx and systemd configuration, and installs `/usr/local/sbin/deploy-nodeapp`.
- Jenkins publishes versioned app archives to the artifact bucket and calls SSM to bootstrap the DB and deploy the web app. The public URL is HTTP; TLS awaits domain/certificate configuration.
- Root Terraform outputs expose URL, web public IP/DNS, VPC, subnet IDs, DB private IP, S3 bucket, and EC2 instance IDs.

# CloudNest: Project Documentation

**DevSecOps microservices platform on AWS (online food ordering)**
Final year project, Cloud Computing | Status: **in progress**

---

## 1. Overview

CloudNest is an online food ordering application used as a realistic workload to demonstrate how modern cloud systems are built, deployed and operated. The focus is on the cloud engineering: networking, containers, infrastructure as code, automated delivery, security and monitoring.

The application is split into small independent services (menu, orders, payments) that run as Docker containers on AWS.

## 2. Problem and objectives

**Problem:** a single-server application goes down when the server fails or traffic spikes, is slow and error-prone to deploy by hand, and often treats security and cost as an afterthought.

**Objectives**
1. Run the app as containerised microservices across 2 Availability Zones.
2. Create all infrastructure from code (Terraform), repeatable with one command.
3. Automate testing, security scanning, building and deployment (GitHub Actions).
4. Keep the database and services in private subnets.
5. Monitor health with dashboards and alerts, and test recovery from failure.
6. Control cost by using free credits and destroying resources after use.

## 3. Target architecture

```
Users
  |
  v
Application Load Balancer        (public subnets)
  |
  v
ECS Fargate services             (private subnets)
  - menu service
  - order service
  - payment service
  |
  v
RDS database                     (private subnets)

Delivery:   Developer -> GitHub -> GitHub Actions (test, scan, build) -> ECR -> ECS
Operations: CloudWatch + Grafana (monitoring), Terraform (all infrastructure)
```

See `architecture.png` for the diagram.

## 4. Technology stack

| Area | Technology | Why |
|---|---|---|
| Cloud | AWS (region ap-south-1, Mumbai) | Most widely used cloud, free credits for new accounts |
| Network | VPC, subnets, internet gateway, route tables | Isolated network with public and private tiers |
| Compute | ECS Fargate | Runs containers without managing servers |
| Containers | Docker, Amazon ECR | Same image runs everywhere, versioned in a registry |
| Database | Amazon RDS | Managed database with backups |
| IaC | Terraform | Repeatable, reviewable infrastructure |
| CI/CD | GitHub Actions | Automated test, scan, build and deploy |
| Monitoring | CloudWatch, Grafana | Metrics, dashboards, alerts |
| Application | Python, Flask, Gunicorn | Simple to read and containerise |

## 5. Repository structure

```
cloudnest/
  app/                  application code and Dockerfiles
    menu-service/
  terraform/            infrastructure as code
  docs/                 documentation, diagrams, screenshots
  .github/workflows/    CI/CD pipeline definitions
```

## 6. What is built so far

### 6.1 Account and access (done)
- AWS account on the Free plan, with sign-up credits.
- Root user protected with MFA and not used for daily work.
- IAM admin user `cloudnest-admin` with MFA, used for all work.
- AWS CLI, Terraform, Git and Docker installed and working.
- Private GitHub repository with the project structure.

### 6.2 Network (done, built with Terraform)

| Resource | Name | Availability Zone | CIDR |
|---|---|---|---|
| VPC | cloudnest-vpc | n/a | 10.0.0.0/16 |
| Public subnet | public-1 | ap-south-1a | 10.0.1.0/24 |
| Public subnet | public-2 | ap-south-1b | 10.0.2.0/24 |
| Private subnet | private-1 | ap-south-1a | 10.0.11.0/24 |
| Private subnet | private-2 | ap-south-1b | 10.0.12.0/24 |

- An internet gateway and a public route table send outside traffic (0.0.0.0/0) to the internet. Public subnets use it.
- A private route table has no internet route, so private subnets are not reachable from the internet.
- 13 resources created by `terraform apply`. No NAT Gateway, because it has an hourly cost.

Files: `terraform/providers.tf`, `variables.tf`, `vpc.tf`, `outputs.tf`.

### 6.3 Menu service (done, runs locally in Docker)

A small Flask service with these endpoints:

| Endpoint | Returns |
|---|---|
| `GET /health` | Service status (used later by the load balancer) |
| `GET /menu` | All menu items |
| `GET /menu/<id>` | One item, or 404 if not found |

The Dockerfile uses a slim Python image, installs pinned dependencies, runs the app with Gunicorn and runs as a non-root user.

### 6.4 Container registry, ECR (done, built with Terraform, added 09-10-2026)

- Private repository `cloudnest/menu-service` in ap-south-1, created by `terraform/ecr.tf` (2 resources).
- **Scan on push** is enabled, so every image is checked for known vulnerabilities.
- A **lifecycle policy** keeps only the last 5 images to keep storage and cost minimal.
- The menu service image is pushed as `latest`. Artifact type: Image. Digest `sha256:199c2d09...8163`.
- **Scan result:** 0 Critical, 1 High, 0 Medium, 0 Low. The High findings were later identified (see section 9).

### 6.5 ECS Fargate (menu service running in the cloud, added 10 and 11-10-2026)

Built with Terraform in `terraform/ecs.tf` and `terraform/ecs_service.tf` (7 resources):

| Resource | Name | Purpose |
|---|---|---|
| ECS cluster | cloudnest-cluster | Logical home for the containers (free while idle) |
| CloudWatch log group | /ecs/cloudnest-menu | Container logs, kept 7 days to limit cost |
| IAM role | cloudnest-ecs-execution-role | Lets ECS pull the image from ECR and write logs |
| Security group | cloudnest-menu-sg | Allows TCP 5000 (temporary test access) |
| Task definition | cloudnest-menu | ECR image, 0.25 vCPU, 0.5 GB, logs to CloudWatch |
| ECS service | cloudnest-menu-service | Keeps the desired number of tasks running |

- The task runs in the **public subnets with a public IP** so it can pull from ECR without a NAT Gateway (cost decision, temporary).
- Verified: `http://<task-public-ip>:5000/menu` returns the four menu items, served from AWS.
- The public IP is **temporary** and changes every time the task starts. A load balancer will give a stable address.
- A variable `menu_desired_count` switches the service on (1) or off (0). With 0 the task stops and billing for it stops. `[0, 0, 0]` in the service status means stopped on purpose, not a fault.

### 6.6 Load balancer (done, added 12-10-2026)

Built with Terraform in `terraform/alb.tf`:

| Resource | Name | Purpose |
|---|---|---|
| Security group | cloudnest-alb-sg | Allows HTTP (port 80) from the internet to the load balancer only |
| Application Load Balancer | cloudnest-alb | One stable DNS address across both public subnets |
| Target group | cloudnest-menu-tg | The healthy containers, checked on /health every 30 seconds |
| Listener | HTTP port 80 | Forwards requests to the menu target group |

- The menu service security group now accepts port 5000 only from the load balancer security group.
- Verified: both targets showed healthy, and the menu was reachable through the load balancer address without a port number.
- The load balancer bills by the hour, so it is removed after testing and rebuilt with terraform apply.

### 6.7 Database, RDS PostgreSQL (done, added 13-10-2026)

Built with Terraform in `terraform/rds.tf`:

| Resource | Name | Purpose |
|---|---|---|
| Security group | cloudnest-db-sg | Allows PostgreSQL (5432) only from the menu service security group |
| DB subnet group | cloudnest-db-subnets | Places the database in the two private subnets |
| RDS instance | cloudnest-db | PostgreSQL 16, db.t4g.micro, 20 GB gp3, encrypted |

Verified with the AWS CLI: status available, PubliclyAccessible false, MultiAZ false, StorageEncrypted true, master password secret active.

- The database bills by the hour, so it is created for testing and removed afterwards (create about 6 minutes, delete about 4 minutes).
- The password is managed by AWS in Secrets Manager. ECS will inject it into the container as an environment variable at start, using the task execution role (permission added in order.tf).

### 6.8 Order service (built and tested locally, pushed to ECR, added 13-10-2026)

Files in `app/order-service`: `app.py`, `requirements.txt`, `Dockerfile`, `.dockerignore`.

| Endpoint | Purpose |
|---|---|
| `GET /health` | Light check, never touches the database (used by the load balancer) |
| `GET /health/db` | Checks that the database is reachable |
| `POST /orders` | Saves an order (item_id, quantity) |
| `GET /orders` | Lists the latest 50 orders |

- Database settings come from environment variables (DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, DB_SSLMODE), so no password is in the code.
- The orders table is created automatically on first use.
- Tested locally with a throwaway PostgreSQL container on a Docker network: health OK, database reachable, two orders created and listed.
- Second ECR repository `cloudnest/order-service` created with Terraform (same scan on push and lifecycle policy). Image pushed as a normal scannable image.
- Deployed to ECS in section 6.9.

### 6.9 Order service in ECS and the paid-resources switch (done, added 14-10-2026)

Built with Terraform in `terraform/order.tf` and `terraform/switch.tf`. The load balancer, database and menu service files were changed to follow the switch.

| Resource | Name | Purpose |
|---|---|---|
| Variable | enable_paid | Controls all hourly-billed resources (default false) |
| Security group | cloudnest-order-sg | Order service port 5000 from the load balancer only |
| Target group | cloudnest-order-tg | Healthy order containers, checked on /health |
| Listener rule | /orders and /orders/* | Sends these paths to the order service |
| Log group | /ecs/cloudnest-order | Order container logs, kept 7 days |
| Execution role policy | read-db-secret | GetSecretValue on the one database secret |
| Task definition | cloudnest-order | Order image from ECR, 0.25 vCPU, 0.5 GB, secrets injected |
| ECS service | cloudnest-order-service | Keeps the order container running behind the load balancer |

- ECS fetches the database user and password from Secrets Manager when the container starts and passes them in as DB_USER and DB_PASSWORD. The password is never in code, Git or Terraform files.
- The connection uses DB_SSLMODE=require (encrypted).
- The database security group now accepts PostgreSQL only from the order service.
- Tested through the load balancer: /menu served by the menu service, orders created and listed through /orders. No errors.
- Afterwards enable_paid was set to false, which destroyed the 8 paid resources. Checks showed no load balancer, no database, no tasks and no leftover secret.

### 6.10 Payment service (done, added 20-10-2026)

Files in `app/payment-service`: `app.py`, `requirements.txt`, `Dockerfile`, `.dockerignore`. Terraform: a third repository in `terraform/ecr.tf` and the ECS wiring in `terraform/payment.tf`.

| Endpoint | Purpose |
|---|---|
| `GET /health` | Health check used by the load balancer |
| `POST /pay` | Takes order_id (whole number) and amount (positive number). Approves amounts up to 5000 and declines above. Returns a payment_id. |

| Resource | Name | Purpose |
|---|---|---|
| ECR repository | cloudnest/payment-service | Image storage, scan on push, keeps the last 5 images |
| Security group | cloudnest-payment-sg | Port 5000 from the load balancer only |
| Target group | cloudnest-payment-tg | Healthy payment containers, checked on /health |
| Listener rule | /pay and /pay/* | Sends these paths to the payment service |
| Log group | /ecs/cloudnest-payment | Container logs, kept 7 days |
| Task definition and service | cloudnest-payment | 0.25 vCPU, 0.5 GB, runs behind the load balancer |

- The service is simulated and stateless. It has no database access and no secrets.
- Tested locally: an amount of 249 was approved and an amount of 9000 was declined.
- Tested through the load balancer together with the menu and order services, with no errors.
- The enable_paid switch now controls 11 resources. After testing, enable_paid=false destroyed all 11, and checks showed no load balancer, database, tasks or leftover secret.
- Image scan results for this image are checked with the findings command and recorded in section 9.

### 6.11 CI/CD pipeline (done, added 28-10-2026)

Files: `.github/workflows/build.yml` (the pipeline) and `terraform/cicd.tf` (the AWS side, 3 resources).

| Piece | Purpose |
|---|---|
| IAM OIDC identity provider for GitHub | Lets AWS trust short-lived tokens issued by GitHub Actions |
| IAM role cloudnest-github-actions | Assumed by workflows on the main branch of this repository only |
| Role policy | ECR login, push and scan results for the three repositories, and describe and redeploy services in the cluster |
| GitHub variable AWS_ROLE_ARN | Holds the role address, so the account ID is not in the code |

**What the pipeline does on every push to main that changes app code or the workflow**
1. Builds the menu, order and payment images in parallel (a matrix).
2. Pushes each image tagged with the commit ID.
3. Waits for the ECR scan and fails the build if there is any Critical finding. High findings only raise a warning.
4. Publishes the image as latest only after the scan has passed.
5. Redeploys each service that is running, and skips services that are not running (enable_paid is off).

- Login uses OIDC, so no AWS access keys are stored anywhere.
- The role trust rule matches the exact subject GitHub sends, which includes numeric owner and repository IDs (found by printing the claims in a temporary debug workflow).
- The scan step polls ECR until the scan is complete, because the scan starts a moment after the push. Verified: a full run passes with all three builds green and the deploy job skipping services that are not running.
- The pipeline cannot create paid resources. It only builds, scans, publishes and redeploys.
- Build results and scan counts appear in the Actions tab of the repository.
- Actions used: actions/checkout v6, aws-actions/configure-aws-credentials v6 and aws-actions/amazon-ecr-login v2.

### 6.12 Monitoring and failure test (done, added 02-11-2026)

Built with Terraform in `terraform/monitoring.tf`. The topic and subscription are always on and free. The dashboard and alarms follow the enable_paid switch.

| Resource | Purpose |
|---|---|
| SNS topic cloudnest-alerts and email subscription | Delivers alarm and recovery emails (the subscription must be confirmed) |
| Alarm cloudnest-alb-5xx | 5 or more load balancer 5xx errors in a minute |
| Alarms cloudnest-menu, order and payment unhealthy-hosts | An unhealthy container for 2 minutes |
| Alarms cloudnest-menu, order and payment cpu-high | Service CPU above 80 percent for 3 minutes |
| Alarm cloudnest-db-cpu-high | Database CPU above 80 percent |
| Dashboard cloudnest | Requests and 5xx errors, healthy containers per service, service CPU, database CPU and connections |

- Alarms email on both alarm and recovery. Missing data counts as not breaching, so a switched-off system stays quiet.
- A test alarm was triggered with aws cloudwatch set-alarm-state to prove the email path works.
- **Failure test:** one menu task was stopped on purpose while requests were sent to the load balancer. ECS started a replacement automatically and the load balancer registered it once healthy. With one container per service there is a short gap, a deliberate cost trade-off. Production would run two or more containers across zones. Measured in one test (checks every 5 seconds): 3 failed checks, about 15 seconds without a healthy menu container, and full service again within roughly 40 seconds of stopping the task, with no human action.
- Afterwards enable_paid was set to false, which removed all 20 paid resources, and checks confirmed no load balancer, database, tasks or leftover secret.

## 7. How to run

**Menu service locally**
```
cd app/menu-service
docker build -t menu-service .
docker run -d --name menu -p 5000:5000 menu-service
curl http://localhost:5000/menu
docker stop menu && docker rm menu
```

**Network with Terraform**
```
cd terraform
terraform init
terraform plan
terraform apply
terraform destroy      # when finished
```

**Push the image to ECR**
```
$acct = aws sts get-caller-identity --query Account --output text
$repo = "$acct.dkr.ecr.ap-south-1.amazonaws.com"
$pw = aws ecr get-login-password --region ap-south-1
docker login --username AWS --password $pw $repo

docker build --provenance=false --sbom=false -t menu-service .
docker tag menu-service:latest "$repo/cloudnest/menu-service:latest"
docker push "$repo/cloudnest/menu-service:latest"
```
`--provenance=false --sbom=false` is needed so ECR can scan the image (see decisions).

**Start, test and stop the menu service on ECS**
```
cd terraform
terraform apply                                   # starts 1 task (billing starts)

aws ecs describe-services --cluster cloudnest-cluster --services cloudnest-menu-service --region ap-south-1 --query "services[0].[desiredCount,runningCount,pendingCount]"
# wait for [1, 1, 0], then get the new public IP:
$task = aws ecs list-tasks --cluster cloudnest-cluster --region ap-south-1 --query "taskArns[0]" --output text
$eni = aws ecs describe-tasks --cluster cloudnest-cluster --tasks $task --region ap-south-1 --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text
aws ec2 describe-network-interfaces --network-interface-ids $eni --region ap-south-1 --query "NetworkInterfaces[0].Association.PublicIp" --output text
# open http://<that-ip>:5000/menu

terraform apply -var="menu_desired_count=0"       # stops the task (billing stops)
```

**Order service locally (with a throwaway PostgreSQL)**

```
docker network create cloudnest-net
docker run -d --name pg --network cloudnest-net -e POSTGRES_DB=cloudnest -e POSTGRES_USER=cloudnest_admin -e POSTGRES_PASSWORD=localtest postgres:16
cd app/order-service
docker build --provenance=false --sbom=false -t order-service .
docker run -d --name order --network cloudnest-net -p 5001:5000 -e DB_HOST=pg -e DB_USER=cloudnest_admin -e DB_PASSWORD=localtest -e DB_SSLMODE=disable order-service
Invoke-RestMethod -Method Post -Uri http://localhost:5001/orders -ContentType "application/json" -Body '{"item_id":1,"quantity":2}'
Invoke-RestMethod http://localhost:5001/orders
docker stop order pg; docker rm order pg; docker network rm cloudnest-net
```

The local password is a throwaway for a container that exists for a few minutes only.

**Switch paid resources on and off**

```
terraform apply                           # free resources only
terraform plan -var="enable_paid=true"      # preview: 20 paid resources to add
terraform apply -var="enable_paid=true"     # starts billing
# test through the load balancer: http://<alb-dns-name>/menu and /orders
terraform apply -var="enable_paid=false"    # stops billing (removes the 20 paid resources)
```

## 8. Design decisions

| Decision | Reason |
|---|---|
| ECS Fargate instead of EKS | EKS has a fixed hourly control-plane cost and uses credits fast. Fargate is simpler and cheaper for this scale. |
| No NAT Gateway | It costs money every hour. Alternatives will be used for private-subnet access. |
| Two Availability Zones | The system keeps running if one data centre fails. |
| Services and database in private subnets | They are not directly reachable from the internet. |
| Terraform for all infrastructure | Repeatable, reviewable in Git, easy to destroy and rebuild. |
| Non-root container user | Limits damage if a container is compromised. |
| Project kept outside OneDrive | Avoids sync problems with Git and Terraform's large provider files. |
| Image built with `--provenance=false --sbom=false` | Docker Desktop's default build creates an OCI image index that ECR cannot scan. The flags produce a normal image that scans correctly. |
| Scan on push and a lifecycle policy on ECR | Catches vulnerabilities early and keeps only the last 5 images, so storage cost stays near zero. |
| ECR login with a temporary token | The AWS CLI generates a token valid for about 12 hours, so no permanent registry password is stored. |
| Smallest Fargate size (0.25 vCPU, 0.5 GB) | Enough for a small Flask service and the cheapest option for the credits. |
| Task in a public subnet with a public IP (temporary) | Lets the task pull from ECR without a NAT Gateway, which costs money every hour. To be replaced by private subnets behind a load balancer. |
| `menu_desired_count` variable | One value switches the service on or off, so paid resources can be stopped without destroying the setup. |
| 7-day log retention | Keeps CloudWatch log storage small. |
| Application Load Balancer across two Availability Zones | One stable address, and traffic keeps flowing if one zone fails. |
| Health check on /health | Only healthy containers receive traffic, and failed ones are replaced. |
| Service security group allows only the load balancer security group | Closes direct internet access to the containers. |
| PostgreSQL on db.t4g.micro | Free plan eligible instance size and engine, small and cheap for the credits. |
| Database in private subnets, not publicly accessible | Only the application can reach it, never the internet. |
| AWS-managed master password in Secrets Manager | No password in code, Git or Terraform state files. |
| Single zone database (no Multi-AZ) | Multi-AZ doubles the cost. Noted as a trade-off, and production would use Multi-AZ. |
| One ECR repository and one container image per service | Services are built, scanned, versioned and deployed independently. |
| Order service reads settings from environment variables | The same code runs locally and in AWS, and no password is written in code. |
| Separate /health and /health/db endpoints | The load balancer health check never touches the database, so a database problem does not make healthy containers get killed. |
| Scan findings with no available fix are accepted and documented | Debian has no fixed glibc or zlib yet. Fixes will be picked up by scheduled rebuilds. |
| GitHub Actions logs in to AWS with OIDC, not stored keys | GitHub gets a short-lived token for one IAM role. No access keys exist in GitHub or in the repo, so there is nothing to leak or rotate. |
| The IAM role trusts only this repository on the main branch | Other repositories and other branches cannot use it. |
| The pipeline role has least privilege | It can push to the three ECR repositories, read their scan results and redeploy services in one cluster. It cannot touch the database, network, secrets or billing. |
| Images are pushed with the commit ID as the tag | Every build is traceable to the exact code that produced it. |
| latest is published only after the scan passes | A vulnerable image can never become the one ECS pulls. |
| Build fails on Critical findings, High findings only warn | The known High findings are Debian base image packages with no fix yet. Blocking on them would stop all deployments. |
| Deploy step redeploys only services that are running | It works with the enable_paid switch, so the pipeline never creates paid resources. |
| Alarms notify through an SNS topic by email | One topic can feed email today and other channels later, and it keeps alarm logic separate from delivery. |
| Alert email stored in terraform.tfvars, which Git ignores | The address is personal data and stays out of the repository. |
| Alarms and dashboard follow the enable_paid switch | They watch resources that only exist while the switch is on. Missing data counts as fine, so a switched-off system does not send alerts. |
| Alarm thresholds: 5 or more load balancer 5xx errors in a minute, an unhealthy container for 2 minutes, CPU above 80 percent | Simple, explainable thresholds that catch real failures without constant noise. |
| One container per service | Keeps cost low. The failure test shows a short gap while ECS replaces a stopped container. Production would run two or more across zones to remove it. |
| Payment service is simulated and stateless | It demonstrates a third independent microservice without needing a real payment provider or another database. |
| Each service has its own security group, target group, log group and image repository | Services can be scaled, secured, monitored and deployed independently. |
| Path-based rules for /orders and /pay on one load balancer | One public address serves all services, and each service stays private behind it. |
| enable_paid switch (default false) | Every hourly-billed resource (load balancer, database, ECS services) is created only when it is true, so a plain terraform apply can never start billing by surprise. |
| Database password injected by ECS from Secrets Manager | The container receives it as an environment variable at start. It never appears in code, Git or Terraform files. |
| DB_SSLMODE set to require | The connection between the order service and the database is encrypted. |
| Path-based routing on one load balancer | /orders goes to the order service and everything else to the menu service, so one address serves several services. |
| Database security group allows only the order service | Least privilege: the menu service and the internet cannot reach the database. |

## 9. Security measures

- MFA on root and IAM admin users.
- Daily work done as an IAM user, not root.
- No access keys or secrets committed to Git (`.gitignore` excludes state and provider files).
- Private subnets for services and database.
- ECR image scanning on push is enabled. First scan: 0 Critical, 1 High, 0 Medium, 0 Low. The High findings are Debian base image packages (see below).
- Registry login uses a temporary token generated by the AWS CLI, not a stored password.
- ECS uses a dedicated execution role with only the AWS-managed ECS task execution policy.
- Port 5000 is closed to the internet. The service security group accepts traffic only from the load balancer security group (verified: a direct request to the task IP on port 5000 times out).
- **Remaining temporary risk:** tasks still run in public subnets with public IPs (no NAT Gateway, for cost). To be moved to private subnets.
- The database is not publicly accessible and sits in the private subnets. Its security group accepts PostgreSQL (port 5432) only from the menu service security group.
- Database storage is encrypted. The master password is generated and stored by AWS in Secrets Manager (manage_master_user_password), so no password exists in code, Git or Terraform files.
- **Image scan findings (13-10-2026):** both images show 3 High findings: glibc (CVE-2026-5435, CVE-2026-19499) and zlib (CVE-2026-85091). The order image also shows 9 Medium and 3 Low. All High findings are Debian base image packages, not application code or Python libraries.
- Checked inside the image with apt list --upgradable: Debian has no fixed glibc or zlib packages yet (only liblzma5 had an update), so the findings are accepted for now and documented.
- Update (10-11-2026): the pipeline-built menu image shows 4 High findings, the earlier three plus a second zlib finding (CVE-2026-76844). All are Debian base image packages and none is Critical, so the gate passes and High findings raise a warning. A rebuild picks up fixes when Debian publishes them.
- The CI/CD pipeline rebuilds and scans every image on each push to main and blocks the build on any Critical finding. High findings raise a warning.
- GitHub Actions authenticates to AWS with OIDC (short-lived tokens). No AWS access keys are stored in GitHub or the repository. The role can be assumed only by workflows on the main branch of this repository.
- Planned: scheduled rebuilds so base image fixes are picked up when Debian publishes them.
- The payment service has no database access and no secrets. Its security group accepts traffic only from the load balancer, and its image is scanned on push like the others.
- The database security group now accepts PostgreSQL only from the order service security group. The order service security group accepts traffic only from the load balancer.
- The execution role was given one extra permission, GetSecretValue on the single database secret, and nothing broader.
- The enable_paid switch prevents accidental creation of paid resources.
- Alarm emails go through an SNS topic. The subscription must be confirmed by clicking the link in the email, otherwise messages are silently dropped.
- The alert email address is kept in terraform.tfvars, which .gitignore excludes, so it is never pushed to GitHub.
- IAM access to Billing was enabled by the root user (one-time setting) so the admin IAM user can view billing without using root.
- Planned: least-privilege IAM roles, image scanning in the pipeline, encrypted database storage, CloudTrail logging.

## 10. Cost control

- Free plan with sign-up credits, checked in the Billing console.
- Resources that cost money while running (load balancer, database, containers) are created only when needed and removed with `terraform destroy` after each session.
- Current spend: credits used $0.00 at the time of writing ($120 available).
- Account is on the **Free plan**: no charges beyond credits, but the account closes when credits run out or after 6 months, so hourly resources are destroyed after every session.
- Always on and free or very low cost: VPC, subnets, route tables, internet gateway, ECS cluster, security group, IAM role and one small ECR repository.
- **Billed by the hour only while running:** the Fargate task and its public IPv4 address. Stopped with `menu_desired_count=0` after each test.
- **Billed by the hour while it exists:** the load balancer. It is removed after each test with terraform destroy using -target.
- **Billed by the hour while it exists:** the RDS database (about 6 minutes to create, about 4 to delete). It is removed after each session with a targeted destroy.
- **enable_paid switch:** terraform apply creates only free resources. terraform apply -var="enable_paid=true" starts the paid ones (load balancer, database, menu and order services). terraform apply -var="enable_paid=false" removes them (20 resources, about 4 to 5 minutes).
- Adding the payment service raised the switch from 8 to 11 paid resources. Each extra small Fargate task adds only a few cents per hour while it runs.
- The pipeline resources (identity provider, role, policy) are free. GitHub Actions minutes for a private repository are included in the free allowance, and the pipeline never creates paid resources.
- The enable_paid switch now controls 20 resources: the 11 services, load balancer and database resources, plus the CloudWatch dashboard and 8 alarms.
- The SNS topic and email subscription are free and stay on. The dashboard and alarms are small and fall within the CloudWatch free allowance at this scale (check the current CloudWatch pricing page).
- Not used (to avoid cost): NAT Gateway, Multi-AZ database.
- Billing console shows USD 0.00 for October 2026 so far (data can lag about 24 hours, so the ECS status command is the reliable check that nothing is running).

## 11. Roadmap

- [x] AWS account, MFA, IAM admin user
- [x] Tools installed and connected (Git, AWS CLI, Terraform, Docker)
- [x] GitHub repository and structure
- [x] VPC and subnets with Terraform
- [x] Menu service in Docker (local)
- [x] Container registry (ECR) with Terraform, image pushed and scanned
- [x] Run the menu service on ECS Fargate (public subnet, temporary)
- [x] Load balancer and health checks (ALB, target group, health check on /health)
- [x] Database (RDS PostgreSQL) in private subnets (created, verified private and encrypted, then removed to save credits)
- [x] Order service in ECS (secret injected from Secrets Manager, routed through the load balancer, private database)
- [x] Payment service (simulated: approves amounts up to 5000, declines above, routed through /pay)
- [x] CI/CD pipeline with security scanning (GitHub Actions, OIDC login, ECR scan gate, automatic redeploy)
- [x] Monitoring, alerts and dashboards (CloudWatch dashboard, 8 alarms, SNS email alerts)
- [x] Failure testing and recovery demo (stopped a task on purpose, ECS started a replacement)
- [ ] Final presentation, demo and README

## 12. Progress log

| Date | Work done |
|---|---|
| 07-10-2026 | Created AWS account, secured root with MFA, created IAM admin user, installed Git, AWS CLI and Terraform, connected CLI, created GitHub repo. Fixed a Git login issue. |
| 08-10-2026 | Reorganised project structure and moved it out of OneDrive. Wrote and applied Terraform for the VPC (13 resources). Built the menu service and Dockerfile. |
| 09-10-2026 | Created ECR repository with Terraform (scan on push, lifecycle policy). Pushed the menu image. Fixed ECR login errors and the image index scan failure by rebuilding with `--provenance=false`. First scan: 1 High finding noted. |
| 10-10-2026 | Created the ECS cluster, CloudWatch log group, ECS execution role and security group with Terraform (5 resources). |
| 11-10-2026 | Enabled IAM access to Billing. Created the task definition and ECS service with Terraform. Menu service ran on Fargate and returned the menu at the task's public IP. Learned that the IP changes on every start and that `[0, 0, 0]` means stopped on purpose. |
| 12-10-2026 | Added an Application Load Balancer, target group and health check with Terraform. Restricted the service security group to the load balancer only. Fixed a missing ECR image (CannotPullContainerError) by pushing it again. Both targets became healthy. Removed the load balancer and service afterwards to stop billing. |
| 13-10-2026 | Added a private PostgreSQL database on RDS with Terraform (encrypted, not public, AWS-managed password). Verified it was available and private, then removed it. Noticed that a full terraform apply also rebuilt the load balancer and service, and removed them again. |
| 13-10-2026 (later) | Built the order service (Flask and PostgreSQL) and tested it locally against a throwaway PostgreSQL container. Created a second ECR repository with a targeted Terraform apply and pushed the order image. Scanned: 3 High, 9 Medium, 3 Low, all High findings from the Debian base image. |
| 14-10-2026 | Added the enable_paid switch for all hourly-billed resources. Deployed the order service to ECS with the database password injected from Secrets Manager, routed /orders through the load balancer and restricted the database to the order service. Tested through the load balancer with no errors, then removed all paid resources and checked the account was clean. |
| 20-10-2026 | Built the payment service (simulated, no database) and tested it locally. Created a third ECR repository, pushed the image and wired the service into ECS with its own security group, target group and /pay listener rule. Tested all three services through the load balancer, then switched paid resources off (11 destroyed) and checked the account was clean. |
| 28-10-2026 | Built the CI/CD pipeline: GitHub Actions builds the three images, pushes them tagged with the commit ID, waits for the ECR scan, blocks Critical findings, publishes latest only after the scan passes and redeploys running services. Logs in to AWS with OIDC and a least-privilege role created with Terraform (3 resources). |
| 02-11-2026 | Added monitoring: an SNS topic with a confirmed email subscription, a CloudWatch dashboard (requests and 5xx, healthy containers, service CPU, database CPU and connections) and 8 alarms (load balancer 5xx, unhealthy containers per service, CPU per service, database CPU). Sent a test alarm to prove the email arrives. Stopped a service task on purpose to show ECS replacing it. Switched all 20 paid resources off and checked the account was clean. |

## 13. Evidence

The project is shown live rather than with static images. Each result can be reproduced with the commands in section 7:

- Pipeline runs and scan summaries: the Actions tab of this repository.
- Image scan results: aws ecr describe-image-scan-findings (see section 9).
- Infrastructure: terraform plan and apply output.
- Services: requests to the load balancer address for /menu, /orders and /pay.
- Monitoring: the CloudWatch dashboard and a test alarm email.
- Recovery: stopping a service task on purpose and watching ECS replace it.

## 14. Daily notes

### 09-10-2026: ECR and image scanning

**Goal:** create a private registry on AWS and push the menu service image so ECS can run it.

**What I did and why**

| Step | What | Why |
|---|---|---|
| 1 | Wrote `terraform/ecr.tf`, ran `terraform apply` | Registry created as code, repeatable and tracked in Git |
| 2 | Enabled scan on push and a lifecycle policy | Early vulnerability detection and minimal storage cost |
| 3 | Logged in to ECR and pushed `menu-service:latest` | Image is now in AWS, ready for ECS |
| 4 | Rebuilt with `--provenance=false --sbom=false` and pushed again | First push was an image index that cannot be scanned |
| 5 | Checked scan results in the console | 0 Critical, 1 High, 0 Medium, 0 Low |

**Problems and fixes**

1. **`docker push` failed with "no basic auth credentials".** The ECR token was printed on screen instead of being passed to `docker login`, and a plain `docker login` had logged in to Docker Hub instead. Fix: store the token in a variable and run `docker login --username AWS --password $pw $repo`.
2. **Piping the token gave "400 Bad Request".** Windows PowerShell can change the encoding when piping. Fix: use the variable method above.
3. **ECR scan failed with "image index cannot be scanned".** Docker Desktop added provenance metadata. Fix: rebuild with `--provenance=false --sbom=false`. Verified with `aws ecr describe-images` that the media type changed to a normal Docker manifest.
4. **Image not visible in the console.** Wrong region (Stockholm) and wrong registry (Public). Fix: use **Mumbai (ap-south-1)** and the **Private registry**.
5. **"Limit exceeded" on the scan page.** This only limits the manual Scan button to one per image per 24 hours. The automatic scan on push had already completed.

**Open items**
- [ ] Identify the High finding and fix it (planned for the CI/CD stage)
- [ ] Change the Docker Hub password that was typed into a command by mistake

**Next session:** ECS cluster, task definition and service on Fargate (smallest size, public subnet, no NAT Gateway), test in the browser, then `terraform destroy` for hourly-billed resources.

### 10-10-2026: ECS foundation

**Goal:** prepare everything ECS needs before running a container.

| Step | What | Why |
|---|---|---|
| 1 | Created `terraform/ecs.tf` (5 resources) | Cluster, log group, execution role and security group, all free while idle |
| 2 | Checked each piece in the console | Confirms Terraform built what the plan said |

**Problem:** the log group was not visible on the CloudWatch home page. It lives under **Logs, Log management**, and can be checked with `aws logs describe-log-groups`.

### 11-10-2026: Menu service running on ECS Fargate

**Goal:** run the menu service container in AWS and open it in the browser.

| Step | What | Why |
|---|---|---|
| 1 | Enabled IAM access to Billing as root | Lets the admin IAM user see billing without using root |
| 2 | Created `terraform/ecs_service.tf` (task definition and service) | Runs the ECR image on Fargate with the smallest size |
| 3 | Waited for status `[1, 1, 0]`, fetched the public IP, opened `/menu` | Proves the image, network, security group and service work together |

**Problems and fixes**

1. **Billing page showed "IAM user access not activated".** AWS hides billing from IAM users by default. Fix: the root user turns on "IAM user and role access to Billing information" under Account.
2. **Browser said "site can't be reached" for `public-ip:5000`.** The placeholder was typed literally. Fix: replace it with the real public IP.
3. **IP command failed with "Invalid id: None".** The command ran before ECS had started the task. Fix: wait for the service to show `[1, 1, 0]`, then fetch the IP.
4. **Old IP stopped working and status showed `[0, 0, 0]`.** The task had been stopped on purpose and the public IP changes on each start. Fix: run `terraform apply` with no variable to start a new task and fetch the new IP.

**Lessons:** a stopped service shows `[0, 0, 0]` and is not a fault. A public IP is temporary, which is why a load balancer with a stable address comes next. Billing data lags by up to about a day, so the ECS status command is the reliable check that nothing is running.

**Open items**
- [ ] Stop the task after testing (`terraform apply -var="menu_desired_count=0"`) and confirm `[0, 0, 0]`
- [x] Identify the High finding from the ECR scan (glibc and zlib in the Debian base image, see section 9)
- [ ] Save the new screenshots and push them

**Next session:** load balancer for a stable address, then move the service to private subnets and close the open port.

## 15. Concepts explained

### AWS Fargate

**What it is:** a way to run containers without managing servers. I give AWS the container image and the CPU and memory it needs, and AWS finds the capacity, starts the container and replaces it if it fails.

**Fargate vs ECS on EC2**

| | ECS on EC2 | ECS on Fargate |
|---|---|---|
| Servers | I create and manage them | AWS manages them |
| Patching and capacity | My job | AWS's job |
| Billing | Pay for the servers | Pay per task for the CPU and memory requested, while it runs |
| Control | More | Less |
| Good for | Large, steady workloads | Small and medium services, quick setup |

**How it fits in CloudNest**
- Cluster (`cloudnest-cluster`): logical home for the containers.
- Task definition (`cloudnest-menu`): the recipe (image, 0.25 vCPU, 0.5 GB, port, logs).
- Task: one running copy of the recipe.
- Service (`cloudnest-menu-service`): keeps the desired number of tasks running.
- In Terraform this is `launch_type = "FARGATE"`.

**What happens on start:** ECS reads the task definition, Fargate provides an isolated environment, a network interface is attached in the subnet (the public IP), the image is pulled from ECR using the execution role, the container starts and logs go to CloudWatch.

**Why Fargate for this project**
- No servers to manage.
- No cost for idle machines (desired count 0 stops billing for the task).
- Fits microservices, one task definition per service.
- Easy to automate with Terraform and a pipeline.

**Trade-offs**
- Costs more per unit of compute than well-packed EC2 at large, steady scale.
- The underlying machine cannot be customised.
- Each task needs its own network interface and address, so a public IP or NAT Gateway must be planned.
- Startup takes about a minute (environment setup and image pull).

**Alternatives:** Lambda (short event-driven functions), EKS (Kubernetes, fixed control-plane cost, more to learn), EC2 with Docker (most control, most work).

**One line:** Fargate is serverless compute for containers: I define the container and its size, and AWS runs and replaces it.

### 12-10-2026: Load balancer and closing the open port

**Goal:** give the service one stable address and stop exposing the containers directly.

| Step | What | Why |
|---|---|---|
| 1 | Created `terraform/alb.tf` (load balancer, target group, listener, security group) | Stable address, health checks and traffic spread across two zones |
| 2 | Changed the service security group to accept only the load balancer | Closes the open port 5000 risk |
| 3 | Pointed the ECS service at the target group | Containers register with the load balancer automatically |
| 4 | Tested through the load balancer address and confirmed direct access to port 5000 times out | Proves the new design works and the old door is closed |
| 5 | Removed the load balancer and service with terraform destroy | The load balancer bills by the hour even when idle |

**Problems and fixes**

1. **Target list was empty.** The service events showed `CannotPullContainerError ... menu-service:latest: not found`. The image was missing from ECR. Fix: log in again, push the image, then run `aws ecs update-service --force-new-deployment`.
2. **Briefly 2 tasks running while 1 was desired.** This is a normal rolling deployment: the new task starts and becomes healthy before the old one stops.
3. **`terraform destroy -target=aws_lb.main` failed in PowerShell.** The dot was split by PowerShell. Fix: quote the target, for example `terraform destroy "-target=aws_lb.main" "-target=aws_ecs_service.menu"`.

**Lessons:** read the service events first when targets stay empty. Images pushed by hand live inside the repository, so recreating the repository deletes them (the CI/CD pipeline will push automatically later). Private IPs in the target list belong to the containers inside the VPC.

**Checked after the session:** no load balancer and no running tasks, so nothing hourly-billed is left.

**Next session:** database (RDS) in private subnets, then the order and payment services.

### 13-10-2026: Private database on RDS

**Goal:** add the data tier, kept private and secure, and confirm it works before removing it to save credits.

| Step | What | Why |
|---|---|---|
| 1 | Created `terraform/rds.tf` (security group, subnet group, instance) | Database as code, same as the rest |
| 2 | Chose PostgreSQL on db.t4g.micro | Free plan eligible engine
| 3 | Used an AWS-managed password | No password in code, Git or state |
| 4 | Verified status, privacy and encryption with the CLI | Proof the database is available, private and encrypted |
| 5 | Removed the database and checked the account was clean | Database bills by the hour |

**Problem and lesson**

1. **The plan said 6 to add, not 3.** The load balancer, listener and ECS service had been removed with a targeted destroy last time, so a full `terraform apply` rebuilt them together with the database. They were removed again afterwards with `terraform destroy "-target=aws_lb.main" "-target=aws_ecs_service.menu"`. Lesson: read the "Plan: N to add" line before typing yes, and use `-target` when only one piece is wanted.

**Checked at the end:** no load balancer, no running tasks, no database and no leftover secret, so nothing hourly-billed is left.

**Open items**
- [x] Identify the High finding from the ECR scan (glibc and zlib in the Debian base image, see section 9)
- [ ] Push any new screenshots

**Next session:** order and payment services that use the database (IAM task role to read the secret), then the CI/CD pipeline.

### 13-10-2026 (later): Order service and scan findings

**Goal:** build a second service that uses the database, test it locally, and understand the scan findings.

| Step | What | Why |
|---|---|---|
| 1 | Built the order service (Flask, psycopg2) | The first service that uses the data tier |
| 2 | Tested it against a local PostgreSQL container | Proves the code works before any cloud cost or cloud debugging |
| 3 | Added a second ECR repository with a targeted apply | A plain apply would also have rebuilt the load balancer and service |
| 4 | Pushed the image and read the scan | 3 High, 9 Medium, 3 Low |
| 5 | Listed the High findings and checked for fixes inside the image | All are Debian base image packages with no fix yet |

**Findings:** the three High findings (glibc twice, zlib once) are identical in both the menu and order images. apt list --upgradable showed no newer glibc or zlib, so they are accepted and documented. The pipeline will rebuild and rescan regularly.

**Lessons:** test locally first so cloud problems are only cloud problems. Use -target when only one resource should change. A scan finding with no available fix is documented, not worked around.

**Open items**
- [ ] Save screenshots: order-local.png and order-scan.png

**Next session:** a safety switch for the paid resources, the ECS task definition for the order service with the database password injected from Secrets Manager, routing /orders through the load balancer, then create, test and remove.

### 14-10-2026: Order service in ECS and the paid-resources switch

**Goal:** run the order service in the cloud with the database, and make sure paid resources can never start by accident.

| Step | What | Why |
|---|---|---|
| 1 | Added the enable_paid variable and made the load balancer, database and services depend on it | A plain terraform apply had rebuilt paid resources twice by surprise |
| 2 | Created order.tf (security group, target group, listener rule, log group, task definition, service) | The order service runs behind the same load balancer as the menu |
| 3 | Injected the database user and password from Secrets Manager | No password in code, Git or Terraform |
| 4 | Restricted the database to the order service | Least privilege |
| 5 | Switched the paid resources on, tested through the load balancer, then switched them off | Short, cheap test and a clean account afterwards |

**Plan notes:** the first plan showed 4 to add and 1 to destroy instead of 3 to add. The extra pair was the database security group being replaced, because its description changed and AWS cannot edit a description. No database existed at that point, so it was safe.

**Result:** tested through the load balancer with no errors. Switching off destroyed 8 resources, and checks showed no load balancer, no database, no tasks and no leftover secret.

**Open items**
- [ ] Save screenshots: order-cloud.png and ecs-two-services.png
- [x] Payment service (simulated: approves amounts up to 5000, declines above, routed through /pay)
- [ ] CI/CD pipeline with security scanning

**Next session:** the payment service, then the CI/CD pipeline.

### 20-10-2026: Payment service

**Goal:** add the third microservice and run all three behind one load balancer.

| Step | What | Why |
|---|---|---|
| 1 | Built the payment service (Flask, simulated approvals) | A third independent service with a different job |
| 2 | Tested it locally with an approved and a declined payment | Code problems are found before any cloud cost |
| 3 | Created a third ECR repository and pushed the image | One image per service, scanned on push |
| 4 | Wrote payment.tf (security group, target group, /pay rule, task definition, service) | Same pattern as the order service |
| 5 | Checked the plan before each apply | The free part showed 3 to add, and the paid preview showed 11 to add |
| 6 | Switched paid resources on, tested /menu, /orders and /pay through one address, then switched them off | Short, cheap test and a clean account afterwards |

**Result:** all three services were reached through the single load balancer address. Switching off destroyed 11 resources.

**Lessons:** the switch makes the paid cost of each new service visible (8 resources became 11). A new service follows the same repeatable pattern: image, repository, security group, target group, listener rule, task definition and service.

**Open items**
- [ ] Save screenshots: payment-local.png, all-services-cloud.png and ecs-three-services.png
- [ ] Record the payment image scan counts in section 9
- [ ] CI/CD pipeline with security scanning
- [x] Monitoring, alerts and dashboards

**Next session:** the CI/CD pipeline with GitHub Actions: build, scan, push to ECR and deploy on every code push.

### 28-10-2026: CI/CD pipeline

**Goal:** make every code change build, get scanned and ship automatically, without stored cloud keys.

| Step | What | Why |
|---|---|---|
| 1 | Checked the current versions of the GitHub Actions used | Action versions change often |
| 2 | Wrote cicd.tf (OIDC provider, role, least-privilege policy) | AWS trusts GitHub with short-lived tokens, no stored keys |
| 3 | Read the plan before applying | It showed 3 to add, 0 to change, 0 to destroy, as expected |
| 4 | Stored the role address as a GitHub variable | Keeps the account ID out of the code |
| 5 | Wrote build.yml and pushed it | The push itself started the first pipeline run |
| 6 | Watched the run in the Actions tab | Build, scan gate, publish and deploy steps |

**Lessons:** OIDC removes the need for stored keys. Publishing latest only after the scan passes keeps bad images out of production. Blocking on Critical findings but only warning on High is a practical gate when the High findings have no fix yet. The deploy step must check whether a service exists, so the pipeline works with the cost switch.

**Open items**
- [ ] Save screenshots: pipeline-green.png and pipeline-scan-summary.png
- [x] Monitoring, alerts and dashboards
- [x] Failure testing and recovery demo
- [ ] README and final presentation
- [ ] Make the repository public after a final secret check

**Next session:** monitoring with CloudWatch (dashboard and alarms), then a failure test, the README and the presentation.

### 02-11-2026: Monitoring and failure test

**Goal:** see what the system is doing, get emailed when something is wrong, and prove it recovers from a failure.

| Step | What | Why |
|---|---|---|
| 1 | Wrote monitoring.tf (SNS, alarms, dashboard) | The system watches itself and tells me |
| 2 | Kept the alert email in terraform.tfvars | Personal data stays out of Git |
| 3 | Confirmed the email subscription | Unconfirmed subscriptions drop every message |
| 4 | Previewed the paid plan, 20 to add, then switched on | Checked the number matched before billing started |
| 5 | Sent traffic and read the dashboard | Graphs of requests, healthy containers and CPU |
| 6 | Triggered a test alarm | Proved the email path works |
| 7 | Stopped a task on purpose | Showed ECS replacing a failed container |
| 8 | Switched everything off and checked | Nothing hourly-billed left |

**Problem and fix:** the first apply ran before the real email was in terraform.tfvars, so the subscription was created for the placeholder address and could never be confirmed. Terraform replaced it after the file was corrected. The leftover placeholder subscription stays pending in AWS and expires by itself, because AWS cannot delete an unconfirmed subscription. Lesson: fill in variables before the first apply, and always confirm the email link.

**Lessons:** a dashboard shows what is happening, alarms tell you when it matters, and the failure test proves the design. Alarms for resources that only exist while the switch is on must treat missing data as fine.

**Open items**
- [ ] Save screenshots: dashboard.png, alarms.png, alarm-email.png, failure-test.png (crop email and account ID)
- [ ] README
- [ ] Final presentation and demo script
- [ ] Final secret check, then make the repository public

**Next session:** the README and the presentation.

### 10-11-2026: Pipeline debugging

**Goal:** get the CI/CD pipeline from red to green.

| Symptom | Cause | Fix |
|---|---|---|
| Credentials could not be loaded | The AWS_ROLE_ARN variable had never been saved in GitHub | Set the variable and started a fresh run |
| Not authorized to perform sts:AssumeRoleWithWebIdentity | The role trusted a subject without the numeric IDs that GitHub now sends | Printed the real claims in a debug workflow and updated the trust rule |
| Scan step failed within seconds | The step asked for results before ECR had started the scan | Polled until the scan status was COMPLETE |

**Lessons:** read the actual error before changing anything. Print the identity claims instead of guessing the trust rule. A failed gate step correctly stopped the image from being published as latest, and left a commit-tagged image behind that the lifecycle policy removes later. Remove temporary debug workflows once the problem is solved.

**Result:** build-scan-push runs green, publishes the three images and skips deploying services that are not running.

### 11-11-2026: Full system rehearsal

**Goal:** prove the whole system works end to end using the images built by the CI/CD pipeline, then switch everything off.

| Check | Result |
|---|---|
| Switch on | enable_paid=true created 20 resources |
| Services | menu, order and payment running, all three targets healthy behind one load balancer |
| Menu | /menu returned the four items |
| Orders | An order was created and listed. The order service read its database password from Secrets Manager and used the encrypted connection to the private database |
| Payments | 249 approved, 9000 declined |
| Dashboard | All four graphs showed data: a request spike of 39, no 5xx errors, one healthy container per service, CPU under 2 percent for the services, and a startup spike of about 46 percent on the database |
| Alarm email | A test alarm reached my email through SNS |
| Failure test | The menu task was stopped on purpose. 3 failed checks (about 15 seconds), service again within roughly 40 seconds, back to 1 running with no human action |
| Switch off | enable_paid=false destroyed all 20 resources. No load balancer, database, tasks or secrets remained |

**Notes:** the payment service accepts an order id that does not exist, because it is a simulation that does not call the order service. The recovery numbers come from one test with checks every 5 seconds.

**Lessons:** the services run from pipeline-built images, so the cycle commit, build, scan, publish, deploy works end to end. A single container per service gives a short gap on failure. Two or more containers across zones would remove it.
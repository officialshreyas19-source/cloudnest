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
- The password is managed by AWS in Secrets Manager. The application will read it at runtime using an IAM task role, which is still to be built.

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
- Still to do: ECS task definition (database password injected from Secrets Manager), load balancer routing for /orders, and the payment service.

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
The local password is a throwaway for a container that exists for a few minutes only.

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
- Planned: scheduled rebuilds and scans in the CI/CD pipeline, failing the build on Critical findings that have a fix available.
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
- [ ] Order and payment services (order service built, tested locally and pushed to ECR; ECS wiring and payment service still to do)
- [ ] CI/CD pipeline with security scanning
- [ ] Monitoring, alerts and dashboards
- [ ] Failure testing and recovery demo
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

## 13. Screenshots (add as evidence)

Save images in `docs/screenshots/` and link them here.

- [ ] VPC and subnets in the AWS console
- [ ] `terraform apply` complete
- [ ] Menu service in the browser (`/menu`)
- [ ] ECR image details (Artifact type Image, tag latest)
- [ ] ECR scan summary (0 Critical, 1 High)
- [ ] ECS cluster page (Active)
- [ ] ECS task Running
- [ ] Menu service in the browser from AWS (`/menu` at the task IP)
- [ ] CloudWatch log stream for the menu container
- [ ] ECS service running
- [ ] Pipeline passing
- [ ] Monitoring dashboard and alert
- [ ] Failure recovery demo

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
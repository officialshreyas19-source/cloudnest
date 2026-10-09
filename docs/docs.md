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
- **Scan result:** 0 Critical, 1 High, 0 Medium, 0 Low. The High finding is still to be identified and fixed, planned for the CI/CD stage.

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

## 9. Security measures

- MFA on root and IAM admin users.
- Daily work done as an IAM user, not root.
- No access keys or secrets committed to Git (`.gitignore` excludes state and provider files).
- Private subnets for services and database.
- ECR image scanning on push is enabled. First scan: 0 Critical, 1 High, 0 Medium, 0 Low. The High finding is to be identified and fixed.
- Registry login uses a temporary token generated by the AWS CLI, not a stored password.
- Planned: least-privilege IAM roles, image scanning in the pipeline, encrypted database storage, CloudTrail logging.

## 10. Cost control

- Free plan with sign-up credits, checked in the Billing console.
- Resources that cost money while running (load balancer, database, containers) are created only when needed and removed with `terraform destroy` after each session.
- Current spend: credits used $0.00 at the time of writing ($120 available).
- Account is on the **Free plan**: no charges beyond credits, but the account closes when credits run out or after 6 months, so hourly resources are destroyed after every session.
- Currently running: VPC, subnets, route tables and internet gateway (free) and one small ECR repository (very low cost). No NAT Gateway, load balancer, database or containers in AWS.

## 11. Roadmap

- [x] AWS account, MFA, IAM admin user
- [x] Tools installed and connected (Git, AWS CLI, Terraform, Docker)
- [x] GitHub repository and structure
- [x] VPC and subnets with Terraform
- [x] Menu service in Docker (local)
- [x] Container registry (ECR) with Terraform, image pushed and scanned
- [ ] Run services on ECS Fargate
- [ ] Load balancer and health checks
- [ ] Database (RDS) in private subnets
- [ ] Order and payment services
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

## 13. Screenshots (add as evidence)

Save images in `docs/screenshots/` and link them here.

- [ ] VPC and subnets in the AWS console
- [ ] `terraform apply` complete
- [ ] Menu service in the browser (`/menu`)
- [ ] ECR image details (Artifact type Image, tag latest)
- [ ] ECR scan summary (0 Critical, 1 High)
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

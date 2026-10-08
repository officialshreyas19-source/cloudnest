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

## 9. Security measures

- MFA on root and IAM admin users.
- Daily work done as an IAM user, not root.
- No access keys or secrets committed to Git (`.gitignore` excludes state and provider files).
- Private subnets for services and database.
- Planned: least-privilege IAM roles, image vulnerability scanning in the pipeline, encrypted database storage, CloudTrail logging.

## 10. Cost control

- Free plan with sign-up credits, checked in the Billing console.
- Resources that cost money while running (load balancer, database, containers) are created only when needed and removed with `terraform destroy` after each session.
- Current spend: credits used $0.00 at the time of writing.

## 11. Roadmap

- [x] AWS account, MFA, IAM admin user
- [x] Tools installed and connected (Git, AWS CLI, Terraform, Docker)
- [x] GitHub repository and structure
- [x] VPC and subnets with Terraform
- [x] Menu service in Docker (local)
- [ ] Container registry (ECR) with Terraform
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

## 13. Screenshots (add as evidence)

Save images in `docs/screenshots/` and link them here.

- [ ] VPC and subnets in the AWS console
- [ ] `terraform apply` complete
- [ ] Menu service in the browser (`/menu`)
- [ ] ECS service running
- [ ] Pipeline passing
- [ ] Monitoring dashboard and alert
- [ ] Failure recovery demo

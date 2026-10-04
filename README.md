# my_infra — DevOps lab on AWS

A near-production DevOps platform built for learning: Terraform builds the AWS
infrastructure, Ansible bootstraps the cluster, ArgoCD deploys everything
inside Kubernetes from Git, and Prometheus + Grafana watch it. CI/CD comes
next, with GitHub Actions (github.com) and SonarQube Cloud (free plan).

**Start here → [docs/DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md)** (step-by-step, with explanations).

```
my_infra/
├── aws_vpc/                    Terraform: VPC "main" (public + private subnets, IGW, NAT)
│   └── modules/vpc/            reusable VPC module
├── infra/                      ── everything the PLATFORM team owns ──
│   ├── terraform/
│   │   ├── bootstrap/          S3 bucket for Terraform state (+ generates backend.hcl)
│   │   ├── eks/                EKS cluster, private node group, add-ons, IAM (Pod Identity)
│   │   └── tooling/            ECR image registry (+ GitHub Actions OIDC role in the CI/CD phase)
│   ├── ansible/
│   │   ├── inventory/          localhost only - the bootstrap runs from your machine
│   │   └── argocd-bootstrap.yml installs ArgoCD + hands the cluster to GitOps
│   └── kubernetes/             what ArgoCD deploys
│       ├── argocd/             ArgoCD Helm values
│       ├── apps/               app-of-apps chart (one ArgoCD Application per component)
│       ├── platform/storage/   default gp3 StorageClass
│       └── monitoring/         kube-prometheus-stack values, Grafana dashboards + data sources
├── example-app/                ── everything the APP team owns ──
│   ├── src/ pom.xml            Spring Boot 4 / Java 21 service (Maven, JaCoCo coverage for SonarQube Cloud)
│   ├── Dockerfile              multi-stage, non-root, layered image
│   └── k8s/                    Kustomize manifests ArgoCD syncs (deployment, service,
│                               ingress, hpa, pdb, servicemonitor, prometheusrule)
└── docs/DEPLOYMENT-GUIDE.md
```

## How the reference picture maps onto this repo

| Picture | Here | Notes |
|---|---|---|
| `.github/workflows/ci-cd.yml` | *next phase* | GitHub Actions on github.com (GitHub-hosted runners). Setup steps are in guide Phase 10 |
| `src/`, `pom.xml`, `Dockerfile` | `example-app/` | Kept separate from infra |
| `k8s/` deployment, service, configmap, ingress | `example-app/k8s/` | ConfigMap is generated from `configmap.env`; added HPA, PDB, ServiceMonitor, alert rules |
| `terraform/` main, variables, outputs, tfvars | `aws_vpc/`, `infra/terraform/*` | Split into small stacks with separate state; `terraform.tfvars.example` files |
| `ansible/` inventory.ini, playbook.yml | `infra/ansible/` | Bootstraps ArgoCD onto the cluster. No servers to configure: the nodes are managed by EKS, and the build tools are SaaS |
| `monitoring/prometheus/prometheus.yml` | `infra/kubernetes/monitoring/` + `example-app/k8s/servicemonitor.yaml` | The Prometheus Operator generates the scrape config |
| `monitoring/grafana/datasources.yml`, `dashboards/dashboard.json` | `infra/kubernetes/monitoring/config/` | Loaded by Grafana's sidecar; CloudWatch data source added |
| *(added)* ArgoCD | `infra/kubernetes/argocd`, `infra/kubernetes/apps` | GitOps: cluster state = Git |
| SonarQube | **SonarQube Cloud** free plan (sonarcloud.io) | Nothing self-hosted. `pom.xml` already points at it and produces coverage |
| AWS: ECR, EC2, VPC, S3, IAM, CloudWatch | all of the above | EC2 = the EKS worker nodes |

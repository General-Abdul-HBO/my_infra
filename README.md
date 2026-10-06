# my_infra — DevOps lab on AWS

A near-production DevOps platform built for learning: Terraform builds the AWS
infrastructure, Ansible bootstraps the cluster, ArgoCD deploys everything
inside Kubernetes from Git, and Prometheus + Grafana watch it. GitHub Actions
(github.com) + SonarQube Cloud (free plan) build, scan and ship every change,
by committing the new image tag to Git for ArgoCD to deploy.

**Start here → [docs/DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md)** (step-by-step, with explanations).

```
my_infra/
├── .github/
│   ├── workflows/ci-cd.yml     PR: build+test+SonarQube Cloud gate · main: + push to ECR + GitOps tag commit
│   └── dependabot.yml          weekly update PRs for Actions, Maven, Docker base images
├── aws_vpc/                    Terraform: VPC "main" (public + private subnets, IGW, NAT)
│   └── modules/vpc/            reusable VPC module
├── infra/                      ── everything the PLATFORM team owns ──
│   ├── terraform/
│   │   ├── bootstrap/          S3 bucket for Terraform state (+ generates backend.hcl)
│   │   ├── eks/                EKS cluster, private node group, add-ons, IAM (Pod Identity)
│   │   └── tooling/            ECR image registry + GitHub Actions OIDC role (no stored AWS keys)
│   ├── ansible/
│   │   ├── inventory/          localhost only - the bootstrap runs from your machine
│   │   └── argocd-bootstrap.yml installs ArgoCD + hands the cluster to GitOps
│   └── kubernetes/             what ArgoCD deploys
│       ├── argocd/             ArgoCD Helm values
│       ├── apps/               app-of-apps chart (one ArgoCD Application per component, incl. Istio + Kiali)
│       ├── platform/storage/   default gp3 StorageClass
│       ├── platform/istio/     mesh-wide STRICT mTLS
│       ├── platform/istio-ingress/  Istio Gateway listener + the public ALB in front of it
│       └── monitoring/         kube-prometheus-stack values, Grafana dashboards, Istio scrape config
├── example-app/                ── everything the APP team owns ──
│   ├── src/ pom.xml            Spring Boot 4 / Java 21 service (Maven, JaCoCo coverage for SonarQube Cloud)
│   ├── Dockerfile              multi-stage, non-root, layered image
│   └── k8s/                    Kustomize manifests ArgoCD syncs (deployment, service, virtualservice,
│                               authorizationpolicy, hpa, pdb, servicemonitor, prometheusrule)
└── docs/DEPLOYMENT-GUIDE.md
```

## How the reference picture maps onto this repo

| Picture | Here | Notes |
|---|---|---|
| `.github/workflows/ci-cd.yml` | `.github/workflows/ci-cd.yml` | GitHub Actions on github.com (GitHub-hosted runners). Deploys by committing the new tag, and ArgoCD rolls it out. Setup: guide Phase 10 |
| `src/`, `pom.xml`, `Dockerfile` | `example-app/` | Kept separate from infra |
| `k8s/` deployment, service, configmap, ingress | `example-app/k8s/` | ConfigMap is generated from `configmap.env`. The Ingress is replaced by an Istio VirtualService on the shared gateway. Added AuthorizationPolicy, HPA, PDB, ServiceMonitor, alert rules |
| *(added)* Istio service mesh | `infra/kubernetes/apps/templates/istio.yaml`, `infra/kubernetes/platform/istio*` | Envoy sidecars, STRICT mTLS, ingress gateway behind the ALB, Kiali. Guide Phase 11 |
| `terraform/` main, variables, outputs, tfvars | `aws_vpc/`, `infra/terraform/*` | Split into small stacks with separate state; `terraform.tfvars.example` files |
| `ansible/` inventory.ini, playbook.yml | `infra/ansible/` | Bootstraps ArgoCD onto the cluster. No servers to configure: the nodes are managed by EKS, and the build tools are SaaS |
| `monitoring/prometheus/prometheus.yml` | `infra/kubernetes/monitoring/` + `example-app/k8s/servicemonitor.yaml` | The Prometheus Operator generates the scrape config |
| `monitoring/grafana/datasources.yml`, `dashboards/dashboard.json` | `infra/kubernetes/monitoring/config/` | Loaded by Grafana's sidecar; CloudWatch data source added |
| *(added)* ArgoCD | `infra/kubernetes/argocd`, `infra/kubernetes/apps` | GitOps: cluster state = Git |
| SonarQube | **SonarQube Cloud** free plan (sonarcloud.io) | Nothing self-hosted. Quality gate blocks the pipeline; JaCoCo coverage from `pom.xml` |
| AWS: ECR, EC2, VPC, S3, IAM, CloudWatch | all of the above | EC2 = the EKS worker nodes |

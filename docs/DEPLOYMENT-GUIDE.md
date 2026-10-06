# Deployment Guide — EKS + ArgoCD + Prometheus/Grafana on AWS

This guide takes you from the VPC you already have to a running platform:

- an EKS cluster whose worker nodes sit in **private subnets**
- ArgoCD continuously deploying from Git (GitOps)
- an example Spring Boot app behind an AWS load balancer and an **Istio
  service mesh** (Envoy sidecars, mutual TLS between services, Kiali)
- Prometheus, Grafana and Alertmanager monitoring it
- a CI/CD pipeline on **GitHub Actions** (github.com) with the free plan of
  **SonarQube Cloud** for code scanning, deploying through ArgoCD (GitOps)

Every phase ends with a **Verify** step, and the boxes marked 🧠 explain *why*
things are done this way. Don't skip those: understanding them is the point.

> You'll first deploy by hand (Phases 5 and 9: build → push → bump tag →
> ArgoCD deploys), then automate exactly those steps with the pipeline in
> Phase 10. That way you know what the pipeline is doing for you.

---

## Contents

0. [The big picture](#0-the-big-picture)
1. [Set up your workstation (WSL2)](#1-set-up-your-workstation-wsl2)
2. [Put the repo on GitHub](#2-put-the-repo-on-github)
3. [Phase 1 — Terraform state bucket](#phase-1--terraform-state-bucket-bootstrap)
4. [Phase 2 — VPC: remote state + load-balancer tags](#phase-2--vpc-remote-state--load-balancer-tags)
5. [Phase 3 — EKS cluster](#phase-3--eks-cluster)
6. [Phase 4 — Tooling: ECR image registry](#phase-4--tooling-ecr-image-registry)
7. [Phase 5 — Build and push the app image](#phase-5--build-and-push-the-app-image)
8. [Phase 6 — Bootstrap ArgoCD (GitOps)](#phase-6--bootstrap-argocd-gitops)
9. [Phase 7 — Reach the app](#phase-7--reach-the-app)
10. [Phase 8 — Monitoring](#phase-8--monitoring)
11. [Phase 9 — GitOps exercises](#phase-9--gitops-exercises)
12. [Phase 10 — CI/CD: GitHub Actions + SonarQube Cloud + GitOps](#phase-10--cicd-github-actions--sonarqube-cloud--gitops)
13. [Day-2 operations](#day-2-operations-patching-and-upgrades)
14. [Costs and teardown](#costs-and-teardown)
15. [Troubleshooting](#troubleshooting)
16. [What's next](#whats-next)

Also: [Phase 11 — Service mesh: Istio sidecars, mTLS, Kiali](#phase-11--service-mesh-istio-sidecars-mtls-kiali)
(Istio is installed automatically in Phase 6; Phase 11 is where you explore it.)

---

## 0. The big picture

```
                                   Internet
                                       │
              ┌────────────────────────┼─────────────────────────────────┐
              │ VPC "main" 10.0.0.0/16 │  (3 availability zones)          │
              │                        ▼                                  │
  PUBLIC      │   Internet Gateway ◄── ALB (devops-lab-public)  NAT GW ───┼──► internet:
  10.0.1-3.0  │                         │                    ▲  (1 EIP)  │    OS patches,
              │                         │                    │           │    image pulls,
              │ ────────────────────────┼────────────────────┼────────── │    GitHub
  PRIVATE     │                         ▼                    │           │
  10.0.4-6.0  │   EKS worker nodes (no public IPs) ──────────┘           │
              │    Istio ingress gateway (Envoy)                          │
              │          │ mutual TLS                                     │
              │          ▼                                                │
              │    [ Envoy sidecar | example-app ]  ← each app pod        │
              └───────────────────────────────────────────────────────────┘

  You ──HTTPS (your IP only)──► EKS API endpoint      (kubectl, helm, Ansible)
  ArgoCD (in EKS) ──polls──► your repo on github.com  (via the NAT gateway)

  CI/CD (Phase 10 - SaaS, nothing to host):
  git push ─► GitHub Actions ─► SonarQube Cloud (scan) ─► ECR (image) ─► Git (new tag) ─► ArgoCD
```

**Who does what**

| Tool | Responsibility | Lives in |
|---|---|---|
| Terraform | AWS resources: VPC, EKS, IAM, ECR, S3 | `aws_vpc/`, `infra/terraform/` |
| Ansible | One-time cluster bootstrap: installs ArgoCD and hands the cluster over to Git | `infra/ansible/` |
| ArgoCD | Everything *inside* Kubernetes, continuously synced from Git | `infra/kubernetes/`, `example-app/k8s/` |
| Prometheus / Grafana | Metrics, dashboards, alerts | `infra/kubernetes/monitoring/` |
| Istio (+ Kiali) | Service mesh: ingress gateway, mTLS between pods, traffic rules, mesh telemetry | `infra/kubernetes/apps/templates/istio.yaml`, `infra/kubernetes/platform/istio*`, `example-app/k8s/` |
| GitHub Actions + SonarQube Cloud | Build, test, scan, push the image, bump the tag in Git | `.github/workflows/ci-cd.yml` |

🧠 **Why split it like this?** Each tool does the job it's best at. Terraform
creates cloud resources. Ansible runs a sequence of setup steps (here: install
ArgoCD, create secrets, hand over). ArgoCD keeps the cluster matching Git and
undoes manual drift. CI builds and checks code. If something is wrong, you
know which layer to look at.

**Terraform stacks and order** (each has its own state file):

```
bootstrap (state bucket) → aws_vpc → eks → tooling (ECR + GitHub Actions OIDC role)
                                     └─ eks finds the VPC by its Name tag "main"
```

**Time:** about 2 hours the first time. **Cost while running:** roughly
**$0.36/hour (~$8.50/day)**. See [Costs and teardown](#costs-and-teardown) and
destroy what you're not using.

---

## 1. Set up your workstation (WSL2)

Ansible doesn't run on Windows, so do **everything** from your WSL Ubuntu
shell. One environment means no "works in PowerShell but not in bash" surprises.

### 1.1 Open Ubuntu

From PowerShell: `wsl -d Ubuntu-24.04` (or open "Ubuntu 24.04" from the Start menu).

### 1.2 Install the tools

```bash
sudo apt update
sudo apt install -y unzip curl git jq rsync python3-venv python3-pip ca-certificates gnupg lsb-release

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update

# Session Manager plugin (optional: shell into EKS nodes without SSH)
curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb
sudo dpkg -i /tmp/smp.deb

# Terraform (HashiCorp apt repo)
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# kubectl, matching the cluster's minor version (1.36)
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable-1.36.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# Helm 3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# istioctl - Istio's debugging CLI (Phase 11), same version as the mesh
curl -fsSL https://github.com/istio/istio/releases/download/1.30.5/istioctl-1.30.5-linux-amd64.tar.gz | tar xz -C /tmp
sudo install -m 0755 /tmp/istioctl /usr/local/bin/istioctl
```

**Docker:** open Docker Desktop on Windows → *Settings → Resources → WSL
integration* → enable **Ubuntu-24.04** → *Apply & restart*. Then `docker ps`
works inside WSL.

**Verify**

```bash
aws --version; terraform version; kubectl version --client
helm version --short; docker version --format '{{.Server.Version}}'
```

### 1.3 AWS credentials

Use the same identity you used for the VPC. Either copy your Windows config
(`mkdir -p ~/.aws && cp /mnt/c/Users/abdul/.aws/* ~/.aws/`) or run `aws configure`.

```bash
aws sts get-caller-identity     # shows your account ID and user/role ARN
```

🧠 Whoever runs `terraform apply` for EKS automatically becomes cluster admin.
Use one identity throughout. If you switch profiles, set `AWS_PROFILE` the
same way in every shell.

### 1.4 Move the repo into the Linux filesystem

```bash
mkdir -p ~/code
rsync -a --exclude '.terraform/' /mnt/c/Users/abdul/Desktop/my_infra/ ~/code/my_infra/
cd ~/code/my_infra
ls aws_vpc/terraform.tfstate     # your live VPC state came along - good
```

🧠 **Why not just work in `/mnt/c/...`?** It mostly works, but `/mnt/c` is
your Windows drive reached through a translation layer:
- **Slow:** file-heavy commands (`terraform init`, `docker build`, `mvn`,
  `git status`) are often several times slower than on WSL's own Linux disk.
- **Fake permissions:** every file appears as `rwxrwxrwx` and `chmod` does
  nothing. Ansible then **ignores `ansible.cfg`** (world-writable folder), Git
  sees every file as executable (noisy diffs), and SSH rejects private keys
  kept there.
- **Line endings:** mixing Windows and Linux tools on one checkout can turn
  scripts into CRLF (`$'\r': command not found`). The repo's `.gitattributes`
  forces LF for every text file to prevent this.

To keep editing from Windows, open the WSL copy in VS Code from Ubuntu with
`cd ~/code/my_infra && code .`. VS Code connects through its WSL extension,
and its terminal is your Ubuntu shell. From now on work **only** in
`~/code/my_infra`, not the Desktop copy.

### 1.5 Ansible in a virtualenv

```bash
python3 -m venv ~/.venvs/ansible
source ~/.venvs/ansible/bin/activate          # do this in every new shell
pip install -r ~/code/my_infra/infra/ansible/requirements.txt
cd ~/code/my_infra/infra/ansible && ansible-galaxy collection install -r requirements.yml
ansible --version | head -1
```

---

## 2. Put the repo on GitHub

ArgoCD deploys **from Git**, so the repo must be on github.com before Phase 6.
(It's also where the GitHub Actions pipeline runs, in Phase 10.)

1. On github.com create a new repository named `my_infra`, **empty** (no
   README, no .gitignore). **Public** is simplest, and both GitHub Actions and
   SonarQube Cloud are free for public repos. Private works too (see Phases 6 and 10).
2. Push:

```bash
cd ~/code/my_infra
git init -b main
git add .
git status        # check: NO terraform.tfstate, NO *.tfvars, NO .terraform/ listed
git commit -m "Infra (Terraform, Ansible, GitOps) and example app"
git remote add origin https://github.com/<your-user>/my_infra.git
git push -u origin main
```

**Git inside WSL is separate from Git for Windows.** It has its own
`~/.gitconfig` and does **not** know your Windows GitHub login. Set it up once:

```bash
git config --global user.name  "<your-github-username>"
git config --global user.email "<your-email>"
# Reuse the Windows Git Credential Manager (already installed with Git for Windows):
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"
```

The first push opens a browser to sign in to GitHub, and it's remembered after
that. Without a credential helper you get `could not read Username for
'https://github.com'`, because GitHub no longer accepts account passwords for
Git. Alternative: `sudo apt install gh && gh auth login && gh auth setup-git`.

Push with `-u origin main` the first time (as above). It links your local
`main` to GitHub's, so later plain `git push` commands work. Otherwise you get
*"The current branch main has no upstream branch"*.

🧠 `.gitignore` keeps state files, tfvars and the generated `backend.hcl` out
of Git. Terraform state can contain secrets, so it never belongs in a repo,
and especially not a public one.

---

## Phase 1 — Terraform state bucket (bootstrap)

So far your VPC state is a file on your laptop. Lose the laptop, lose track of
your infrastructure. Shared, remote state in S3 fixes that.

```bash
cd ~/code/my_infra/infra/terraform/bootstrap
terraform init
terraform apply          # review, type "yes"
cat ../backend.hcl
```

`backend.hcl` (generated) looks like:

```hcl
bucket       = "devops-lab-tfstate-123456789012-us-east-1"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

🧠 **What you just built:**
- **Versioning** lets you restore a previous state if one gets corrupted.
- **Encryption and a TLS-only bucket policy** protect the secrets inside state.
- **Native S3 locking** (`use_lockfile`, Terraform ≥ 1.10) stops two
  `apply`s running at once. The old way needed a DynamoDB table.
- **Partial backend config:** each stack declares only its `key`, and the
  bucket details come from `backend.hcl`, so no account IDs are hard-coded.
- **Chicken-and-egg:** this stack's own state stays local (the bucket can't
  store state before it exists). It's tiny and rarely changes.

**Verify:** `aws s3 ls | grep tfstate`

---

## Phase 2 — VPC: remote state + load-balancer tags

### 2.1 Move the VPC state into S3

Edit `aws_vpc/versions.tf` and **uncomment** the backend block:

```hcl
  backend "s3" {
    key = "vpc/terraform.tfstate"
  }
```

```bash
cd ~/code/my_infra/aws_vpc
terraform init -migrate-state -backend-config=../infra/terraform/backend.hcl
#   "Do you want to copy existing state to the new backend?"  -> yes
terraform state list        # still lists your 20 VPC resources -> state is in S3 now
mkdir -p ~/tfstate-backup && mv terraform.tfstate* ~/tfstate-backup/
```

### 2.2 Apply the subnet tags

The VPC module now tags public subnets `kubernetes.io/role/elb=1` and private
subnets `kubernetes.io/role/internal-elb=1`.

```bash
terraform plan
```

**Expected: `Plan: 0 to add, 6 to change, 0 to destroy.`** Tags only. If you
see anything being *destroyed*, stop and investigate before applying.

```bash
terraform apply
git add aws_vpc/versions.tf && git commit -m "VPC: remote state" && git push
```

🧠 **Why the tags?** When you create an Ingress, the AWS Load Balancer
Controller has to decide *which subnets* to place the ALB in. It looks for
these tags: `elb` → public subnets (internet-facing), `internal-elb` →
private subnets (internal).

### 2.3 Verify private subnets can reach the internet (patches!)

Private instances have no public IP. Their only way out is the NAT gateway:

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=main-private" \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[DestinationCidrBlock,NatGatewayId,State]' \
  --output table
```

You should see `0.0.0.0/0 → nat-xxxx → active`. That route is what lets the EKS
nodes pull images and download OS patches. In Phase 3.4 you'll *prove* it from
inside the cluster.

🧠 **Single NAT trade-off:** one NAT gateway in us-east-1a serves all three
private subnets. It's cheap (~$33/month), but if that AZ fails, private
subnets lose internet. Production sets `single_nat_gateway = false` (one per AZ).

---

## Phase 3 — EKS cluster

### 3.1 Configure

```bash
cd ~/code/my_infra/infra/terraform/eks
cp terraform.tfvars.example terraform.tfvars
MYIP=$(curl -s https://checkip.amazonaws.com)
sed -i "s|203.0.113.10/32|${MYIP}/32|" terraform.tfvars
cat terraform.tfvars
```

🧠 The Kubernetes API is reachable from the internet, **but only from your IP**.
Nodes use the *private* endpoint inside the VPC, so this restriction never
affects them. Home IP changed and `kubectl` times out? Update the tfvars and
`terraform apply` again.

### 3.2 Plan and apply

```bash
terraform init -backend-config=../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan          # ~15-20 minutes
```

Read the plan before applying. You should recognise:

| Resource | What it is |
|---|---|
| `aws_eks_cluster.this` | control plane, ENIs in private subnets, secrets encrypted with KMS, logs to CloudWatch |
| `aws_eks_node_group.default` | 3× t3.medium, on-demand, one per AZ, in **private subnets**, AL2023, IMDSv2 |
| `aws_eks_addon.*` | VPC CNI (+ network policy), kube-proxy, CoreDNS, Pod Identity agent, EBS CSI driver |
| `aws_iam_role.pod_identity[*]` | IAM roles for EBS CSI, Load Balancer Controller, Grafana |
| `aws_eks_pod_identity_association.*` | maps those roles to Kubernetes service accounts |

### 3.3 Connect and verify

```bash
$(terraform output -raw kubeconfig_command)
kubectl get nodes -o wide
```

**Verify: nodes are private.** `EXTERNAL-IP` is `<none>` and `INTERNAL-IP` is in 10.0.4–6.x:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=devops-lab-eks" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,SubnetId,PrivateIpAddress,PublicIpAddress]' --output table
terraform output node_group_subnet_ids     # same subnet IDs, all private
```

**Verify: add-ons and identities.**

```bash
kubectl get pods -n kube-system            # aws-node, kube-proxy, coredns, ebs-csi-*, eks-pod-identity-agent
aws eks list-pod-identity-associations --cluster-name devops-lab-eks \
  --query 'associations[].[namespace,serviceAccount]' --output table
```

### 3.4 Prove private nodes reach the internet through the NAT

Start a throwaway pod and ask "what's my public IP?":

```bash
kubectl run egress-test --rm -i --restart=Never --image=curlimages/curl -- curl -s https://checkip.amazonaws.com
terraform -chdir=../../../aws_vpc output nat_public_ips
```

The two IPs match. The node has no public IP of its own, so traffic from
private subnets leaves through the **NAT gateway's Elastic IP**. That's the same
path nodes use for OS patches and image pulls. (And the fact that the
`curlimages/curl` image was pulled from the internet at all already proved it.)

🧠 **Why t3.medium and not something smaller?** With the VPC CNI every pod gets
a VPC IP, and the instance type caps how many IPs a node can hold:
t2/t3.micro → **4 pods**, t3.small → 11, t3.medium → **17**, t3.large → 35.
The platform needs ~31 pods (system pods on every node, ArgoCD, Prometheus
stack, the app), so 3 × t3.medium (51 slots, 12 GiB RAM) is the smallest fit.
Check any type with `kubectl get node <name> -o jsonpath='{.status.capacity.pods}'`.

🧠 **Concepts worth understanding here**

- **Managed node group:** AWS launches and replaces the EC2 nodes, and drains
  pods during updates. You never SSH in or patch them by hand; you roll them
  to a new AMI (see Day-2).
- **VPC CNI:** every pod gets a real VPC IP address. That's why the ALB can
  send traffic straight to pod IPs (`target-type: ip`).
- **Pod Identity:** a pod running as service account `kube-system/aws-load-balancer-controller`
  receives short-lived credentials for exactly one IAM role. No access keys
  anywhere, and no pod can borrow another's permissions.
- **Access entries (API mode):** who may use the cluster is managed with EKS
  API objects rather than the old `aws-auth` ConfigMap.
- **`upgrade_policy = STANDARD`:** the AWS default, *extended* support, costs
  6× more per hour once a version ages out. STANDARD avoids that surprise.
- **Optional:** shell into a node without SSH with
  `aws ssm start-session --target <node-instance-id>`.

---

## Phase 4 — Tooling: ECR image registry

```bash
cd ~/code/my_infra/infra/terraform/tooling
terraform init -backend-config=../backend.hcl
terraform apply
terraform output
```

This creates:
- **The ECR repository `example-app`:**
  - **immutable tags:** a pushed tag can never be overwritten;
  - **scan on push:** basic CVE scan of every image;
  - **lifecycle policy:** untagged images expire after 7 days, and only the newest 30 are kept.
- **The GitHub Actions OIDC provider and the `devops-lab-github-actions` role**,
  used by the pipeline in Phase 10. Only workflow runs from
  `General-Abdul-HBO/my_infra` on `main` can assume it, and it may only push
  to this ECR repository.

**Verify:**

```bash
aws ecr describe-repositories --query 'repositories[].repositoryUri'
terraform output github_actions_role_arn
```

`EntityAlreadyExists ... token.actions.githubusercontent.com`? Your account
already has a GitHub OIDC provider (one is allowed per account). Add
`create_github_oidc_provider = false` to `terraform.tfvars` and apply again.

---

## Phase 5 — Build and push the app image

```bash
cd ~/code/my_infra/example-app
docker build --provenance=false -t example-app:0.1.0 .   # compiles, runs 5 unit tests, builds the image
```

(`--provenance=false` pushes a plain image without Docker Desktop's extra
attestation manifest, so ECR's scan and lifecycle rules see one simple image.
The pipeline does the same.)

**Optional local test:**

```bash
docker run --rm -d --name ea -p 8080:8080 -p 8081:8081 example-app:0.1.0
sleep 5; curl -s localhost:8080/ | jq; curl -s localhost:8081/actuator/health/readiness
docker rm -f ea
```

**Push to ECR:**

```bash
REGISTRY=$(terraform -chdir=../infra/terraform/tooling output -raw ecr_registry)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REGISTRY"
docker tag example-app:0.1.0 "$REGISTRY/example-app:0.1.0"
docker push "$REGISTRY/example-app:0.1.0"

# Vulnerability scan results (scan on push)
aws ecr describe-image-scan-findings --repository-name example-app --image-id imageTag=0.1.0 \
  --query 'imageScanFindings.findingSeverityCounts'
```

**Point the manifests at your registry**, then commit:

```bash
cd ~/code/my_infra
sed -i "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com|${REGISTRY}|" example-app/k8s/kustomization.yaml
grep newName example-app/k8s/kustomization.yaml
git add example-app/k8s/kustomization.yaml && git commit -m "example-app: use ECR image" && git push
```

🧠 **Dockerfile highlights:**
- **Multi-stage build:** Maven and the source never reach the final image.
- **Layered jar:** dependencies are their own layer, so a code change pushes a few KB, not 20 MB.
- **Numeric non-root user (10001):** lets Kubernetes enforce `runAsNonRoot`.
- **`MaxRAMPercentage`:** sizes the JVM heap from the container memory limit.

**Immutable tags:** `0.1.0` can never be overwritten, so a tag in Git always
means the exact same bytes. Every new build needs a new tag.

---

## Phase 6 — Bootstrap ArgoCD (GitOps)

### 6.1 Tell ArgoCD where your repo is

`infra/ansible/vars/gitops.yml` already points at
`https://github.com/General-Abdul-HBO/my_infra.git`. Change `gitops_repo_url`
only if you move or fork the repo.

**Private repo?** Create a [fine-grained token](https://github.com/settings/personal-access-tokens)
with read-only **Contents** access to this one repo, then:
`export GITOPS_REPO_TOKEN=github_pat_...`

### 6.2 Run the bootstrap

```bash
cd ~/code/my_infra/infra/ansible
source ~/.venvs/ansible/bin/activate
ansible-playbook argocd-bootstrap.yml
```

What it does (all from your machine; `inventory/localhost.yml` is the only "host"):
1. Reads `cluster_name`, `region` and `vpc_id` from **Terraform outputs**, so you copy-paste no IDs.
2. Updates your kubeconfig.
3. Installs ArgoCD with Helm (`infra/kubernetes/argocd/values.yaml`).
4. Creates the secrets that must not live in Git: the Grafana admin password
   (saved to `~/.devops-lab/grafana-admin-password`) and repo credentials if needed.
5. Creates **one** Application, `root`, which points at `infra/kubernetes/apps`.

Run it a second time: nearly every task reports `ok` rather than `changed`.
That's **idempotency**: describe the desired state, and Ansible only acts on
differences. It's also how you upgrade ArgoCD later.

### 6.3 Watch GitOps take over

```bash
kubectl get applications -n argocd -w
```

Over ~5–10 minutes the apps appear and sync **in waves**:

| Wave | Application | Deploys |
|---|---|---|
| -10 | (AppProjects) | `platform` and `apps` guard rails |
| -6 | istio-base | Istio CRDs |
| -5 | platform-storage, istio-cni, istiod | default `gp3` StorageClass; Istio node agent; Istio control plane + STRICT mTLS policy |
| -4 | aws-load-balancer-controller, metrics-server | ALB controller, resource metrics |
| -3 | istio-ingressgateway | the mesh's front door + **the ALB** in front of it |
| -2 | kube-prometheus-stack | Prometheus, Alertmanager, Grafana, exporters |
| -1 | monitoring-config, kiali | dashboards, CloudWatch data source, Istio scrape config; mesh console |
| 0 | example-app | your app, with an Envoy sidecar in every pod |

The end state is all 13 apps `Synced` and `Healthy`.

🧠 **App-of-apps:** you created one Application by hand, and everything else
is *declared in Git* as more Applications. Adding a component to the cluster
means adding a file under `infra/kubernetes/apps/templates/` and pushing.

🧠 **Sync waves:** the gateway's Ingress needs the load balancer controller's
webhook, the app's ServiceMonitor needs the Prometheus CRDs, and app pods
must be created *after* istiod is running, or they start without a sidecar.
Waves plus the Application health check in `argocd/values.yaml` make ArgoCD
wait for each wave to be **Healthy** before starting the next.

🧠 **AppProjects:** the `apps` project can only deploy into the `example-app`
namespace from your repo. A mistake in app manifests can't touch `kube-system`.

### 6.4 ArgoCD UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

Open **https://localhost:8080** (accept the self-signed certificate) and log in
as `admin` with that password. Click `example-app` to see every Kubernetes
object it owns. After changing the password (*User Info → Update password*),
delete the bootstrap secret: `kubectl -n argocd delete secret argocd-initial-admin-secret`.

---

## Phase 7 — Reach the app

```bash
kubectl get pods -n example-app -o wide        # 2 pods, READY 2/2 (app + Envoy sidecar)
kubectl get ingress -n istio-ingress           # the ALB - ADDRESS appears after ~2 min
ALB=$(kubectl get ingress public -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
```

DNS for a new ALB takes 1–3 minutes. Then:

```bash
curl -s http://$ALB/ | jq                      # version, environment, pod
curl -s "http://$ALB/api/greeting?name=Abdul"  # greeting comes from the ConfigMap
for i in 1 2 3 4 5 6; do curl -s http://$ALB/ | jq -r .pod; done   # load balanced across pods
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/actuator/prometheus   # 404 - actuator isn't public
```

🧠 **The traffic path:**

```
internet → ALB (public subnets) → Istio ingress gateway pod IP (private subnets)
         → mutual TLS → example-app's Envoy sidecar → the app on localhost:8080
```

- **The ALB is shared, owned by the platform** (`infra/kubernetes/platform/istio-ingress/`).
- **Each app owns its route** (`example-app/k8s/virtualservice.yaml`).
- **The ALB health-checks the gateway itself** (port 15021), not any one app.

Phase 11 digs into the mesh.

**Readiness gates:** the gateway pods (`kubectl get pods -n istio-ingress -o
wide`) show a `READINESS GATES 1/1` column. A new gateway pod only counts as
Ready once **the ALB's health check** passes, so gateway rollouts never drop traffic.

**Pod Security `restricted`:** the namespace rejects pods that run as root,
add capabilities, etc. The app's `securityContext` is written to pass. The
injected Envoy sidecar passes too, because the **Istio CNI** agent sets up
traffic redirection on the node, so pods need no privileged init container.

🔒 **Optional:** lock the ALB to your IP by uncommenting `inbound-cidrs` in
`infra/kubernetes/platform/istio-ingress/ingress.yaml`, then push. ArgoCD applies it.

---

## Phase 8 — Monitoring

### 8.1 Grafana

```bash
cat ~/.devops-lab/grafana-admin-password; echo
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open **http://localhost:3000** and log in as `admin`. Then explore:
- **Dashboards → Applications → Example App**: request rate, error rate, p95
  latency, JVM heap, CPU/memory against the limit, HPA replicas, restarts. The
  bottom row is the **Mesh** view from Istio's Envoy sidecars: who calls the
  app, the share of mTLS traffic, and sidecar latency (more in Phase 11).
  This dashboard is `infra/kubernetes/monitoring/config/dashboards/example-app.json`
  in Git.
- **Built-in dashboards:** *Kubernetes / Compute Resources / Namespace (Pods)*
  and *Node Exporter / Nodes*.

### 8.2 Prometheus: is the app being scraped?

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open http://localhost:9090 → *Status → Targets* and find
`serviceMonitor/example-app/example-app/0`, **2/2 up**. Try a query in the
graph view: `sum by (uri, status) (rate(http_server_requests_seconds_count{namespace="example-app"}[5m]))`

🧠 There is no hand-written `prometheus.yml`. The **Prometheus Operator**
generates the scrape config from `ServiceMonitor` objects, and
`example-app/k8s/servicemonitor.yaml` is that config for this app. Alert rules
come from `PrometheusRule` objects (`example-app/k8s/prometheusrule.yaml`). The
app team owns its own monitoring, in its own folder.

### 8.3 Fire an alert

(In a new terminal, set `ALB` again first; see the top of Phase 9.)
Generate traffic where half the requests fail:

```bash
for i in $(seq 1 900); do
  curl -s -o /dev/null "http://$ALB/api/greeting?name=load"
  curl -s -o /dev/null "http://$ALB/api/simulate-error"
  sleep 0.5
done
```

- Grafana: the **Error rate** panel turns red within a minute or two.
- Prometheus → *Alerts*: `ExampleAppHighErrorRate` goes **Pending**, then
  **Firing** after 5 minutes (`for: 5m` avoids paging on a blip).
- Alertmanager:
  `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093` → http://localhost:9093

Try latency too: `curl "http://$ALB/api/slow?ms=1500"` in a loop moves the p95 panel.

### 8.4 CloudWatch inside Grafana

Grafana → *Explore* → data source **CloudWatch**:
- **Metrics:** namespace `AWS/ApplicationELB`, metric `RequestCount` or
  `TargetResponseTime`, dimension your ALB. Or `AWS/NATGateway`
  `BytesOutToDestination` to watch image pulls and patch downloads.
- **Logs:** log group `/aws/eks/devops-lab-eks/cluster`. Query
  `fields @timestamp, @logStream, @message | sort @timestamp desc | limit 20`
  to see the EKS control plane audit and authenticator logs.

🧠 Grafana authenticates to AWS with **Pod Identity** (service account
`monitoring/grafana` → read-only CloudWatch role). There are no keys in the
data source config.

---

## Phase 9 — GitOps exercises

The rule from now on: **change Git, not the cluster.**

New terminal? Re-set the shortcuts used below:

```bash
cd ~/code/my_infra
REGISTRY=$(terraform -chdir=infra/terraform/tooling output -raw ecr_registry)
ALB=$(kubectl get ingress public -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

### A. Change configuration

```bash
cd ~/code/my_infra
sed -i 's/^APP_GREETING=.*/APP_GREETING=Hello from GitOps/' example-app/k8s/configmap.env
git commit -am "example-app: new greeting" && git push
kubectl get pods -n example-app -w     # within ~3 min: new pods roll in, old ones terminate
curl -s "http://$ALB/api/greeting?name=you"
```

ArgoCD polls Git every 3 minutes. To skip the wait:
`kubectl -n argocd annotate application example-app argocd.argoproj.io/refresh=normal --overwrite`

🧠 Why did the pods restart? Kustomize names the ConfigMap with a hash of its
content (`example-app-config-<hash>`). New content means a new name, which
changes the Deployment and triggers a rolling update. A plain ConfigMap edit
would leave pods running on the old values.

### B. Ship a new version by hand (exactly what the Phase 10 pipeline automates)

1. Change something visible, e.g. the version in `example-app/pom.xml` → `0.2.0`.
2. Build and push:
   ```bash
   cd ~/code/my_infra/example-app
   docker build -t "$REGISTRY/example-app:0.2.0" . && docker push "$REGISTRY/example-app:0.2.0"
   ```
3. In a **second terminal**, watch for downtime:
   ```bash
   while true; do curl -s -m 2 http://$ALB/ | jq -r .version || echo FAIL; sleep 0.5; done
   ```
4. Bump the tag and push:
   ```bash
   cd ~/code/my_infra
   sed -i 's/newTag: .*/newTag: "0.2.0"/' example-app/k8s/kustomization.yaml
   git commit -am "example-app 0.2.0" && git push
   ```

The watcher flips from `0.1.0` to `0.2.0` with **no FAILs**. That's
`maxUnavailable: 0`, readiness gates, the `preStop` sleep and graceful
shutdown working together.

### C. Self-healing

```bash
kubectl delete deployment example-app -n example-app
kubectl get deploy -n example-app -w            # ArgoCD recreates it within seconds
kubectl set env deployment/example-app -n example-app HACK=1   # manual drift...
kubectl get deploy example-app -n example-app -o jsonpath='{.spec.template.spec.containers[0].env}'  # ...reverted
```

### D. Rollback

```bash
git revert HEAD --no-edit && git push           # back to 0.1.0 - Git history IS the deployment history
```

### E. Autoscaling

```bash
sudo apt install -y hey      # or without installing: docker run --rm williamyeh/hey -z 3m -c 50 "http://$ALB/api/greeting"
hey -z 3m -c 50 "http://$ALB/api/greeting?name=load"
kubectl get hpa -n example-app -w               # CPU climbs, replicas go 2 -> up to 6, then back after 5 min
```

---

## Phase 10 — CI/CD: GitHub Actions + SonarQube Cloud + GitOps

Now automate what you did by hand in Phase 9-B. The pipeline is
[`.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml). Everything here
uses **free** plans. You need Phases 4–7 done (ECR + OIDC role, ArgoCD and the
app running).

### 10.1 How the pieces fit

```
 Pull request (example-app/** changed)          Push / merge to main
        │                                               │
        ▼                                               ▼
 ┌─ Job 1: Build, test & scan ──────────────────────────────────────────────┐
 │  mvn verify (unit tests + JaCoCo coverage)                               │
 │  → SonarQube Cloud analysis → QUALITY GATE (fails the run if it fails)   │
 └──────────────────────────────────────────────────────────────────────────┘
        │ PR: stops here, results shown on the PR       │ main only:
                                                        ▼
 ┌─ Job 2: Build & push image ──────────────────────────────────────────────┐
 │  AWS login via OIDC (no stored keys) → docker build (tests skipped:      │
 │  job 1 ran them) → push to ECR as example-app:<short-sha>                │
 │  → wait for the ECR vulnerability scan, report it                        │
 └──────────────────────────────────────────────────────────────────────────┘
                                                        ▼
 ┌─ Job 3: Deploy (GitOps commit) ──────────────────────────────────────────┐
 │  set newName/newTag in example-app/k8s/kustomization.yaml                │
 │  → commit "deploy(example-app): <sha> [skip ci]" → push to main          │
 └──────────────────────────────────────────────────────────────────────────┘
                                                        ▼
                         ArgoCD (in EKS) sees the commit → rolling update
```

These are steps 1–10 of the CI/CD flow in your reference picture.

🧠 **Why does CI commit to Git instead of running `kubectl apply`?**
- **CI has no cluster access at all.** Its IAM role can only push to ECR, so a
  leaked or compromised workflow can't touch the cluster.
- **Git is the audit log.** Every deploy is a commit: who, what, when.
  Rollback = `git revert`.
- **One deployer.** ArgoCD alone changes the cluster and keeps it matching Git.
  This "pull" model is the core of GitOps. (An alternative pattern, *ArgoCD
  Image Updater*, watches ECR and writes the tag for you. Same idea, different
  trigger.)

🧠 **Words that sound alike:**
- **GitHub (github.com)** is where your repo lives. That's what you're using.
  (*GitHub Enterprise Server* is the self-installed version. Not used here.)
- **GitHub-hosted runners** are the machines GitHub provides to run Actions
  jobs: `runs-on: ubuntu-latest`, standard GitHub Actions. (*Self-hosted
  runners* are machines you'd run yourself. Not needed.)
- **SonarQube Cloud** (sonarcloud.io, formerly SonarCloud) is Sonar's hosted
  service. (*SonarQube Server* is the self-installed version. Not used here.)

### 10.2 What's free

| Service | Free for | Notes |
|---|---|---|
| GitHub Actions (GitHub-hosted runners) | **public repos** (yours is public): standard runners are free | **private repos** on GitHub Free: a monthly allowance of minutes (2,000 at the time of writing; check *Settings → Billing*) |
| SonarQube Cloud **Free plan** | **public repos** | **private projects up to 50,000 lines of code**; no credit card |

A full pipeline run takes ~4–6 minutes. Only `example-app` (the Java code) is
scanned, not the Terraform or YAML.

### 10.3 Set up SonarQube Cloud

1. Go to **https://sonarcloud.io** → **Log in with GitHub**.
2. **Create an organization** → *Import an organization from GitHub* → pick
   your personal account. When the **SonarQube Cloud GitHub App** install
   screen appears, choose **Only select repositories → `my_infra`**, which is
   least privilege. Pick the **Free** plan.
   Note the **organization key** (e.g. `general-abdul-hbo`).
3. **Analyze new project** → tick `my_infra` → *Set up*. For the **new code
   definition** choose *Previous version*. Note the **project key** (shown under
   *Information*, usually `<org>_my_infra`).
4. **Turn Automatic Analysis OFF:** project → *Administration → Analysis
   Method* → switch off *Automatic Analysis*.
   🧠 Automatic Analysis scans without building, so for Java it can't use
   compiled code and **can't read test coverage**. CI-based analysis from Maven
   gives both. Sonar refuses a CI scan while Automatic Analysis is on.
5. **Create a token:** avatar → *My Account → Security* → *Generate token*,
   named `github-actions`. Copy it now; it's shown only once.
6. **Quality gate:** the default **Sonar way** gate is good to start with. It
   judges only *new* code: no new issues, security hotspots reviewed, ≥ 80%
   test coverage and ≤ 3% duplication. Old code doesn't block you; new code
   has to be clean ("clean as you code").

### 10.4 Configure the GitHub repo

Get the role ARN that Phase 4 created:

```bash
terraform -chdir="$HOME/code/my_infra/infra/terraform/tooling" output -raw github_actions_role_arn
```

Then on github.com: repo → *Settings → Secrets and variables → Actions*:

| Tab | Name | Value |
|---|---|---|
| **Secrets** | `SONAR_TOKEN` | the token from 10.3 step 5 |
| Variables | `SONAR_ORGANIZATION` | your organization key |
| Variables | `SONAR_PROJECT_KEY` | your project key |
| Variables | `AWS_REGION` | `us-east-1` |
| Variables | `AWS_ROLE_ARN` | the ARN printed above |
| Variables *(optional)* | `ECR_FAIL_ON_CRITICAL` | `true` = block deploys of images with CRITICAL CVEs |

With GitHub CLI (`gh auth login` first), the same from your terminal:

```bash
gh secret set SONAR_TOKEN                      # paste the token when prompted
gh variable set SONAR_ORGANIZATION --body "<org-key>"
gh variable set SONAR_PROJECT_KEY  --body "<project-key>"
gh variable set AWS_REGION         --body "us-east-1"
gh variable set AWS_ROLE_ARN       --body "$(terraform -chdir=infra/terraform/tooling output -raw github_actions_role_arn)"
```

🧠 **Secrets vs variables:** secrets are encrypted and masked in logs, so use
them for anything that grants access. Variables are plain config. The role
ARN isn't secret: on its own it grants nothing, because only GitHub's signed
token for *your repo on `main`* can assume it.

🧠 **Permissions:** the workflow starts every job read-only
(`permissions: contents: read`) and elevates only where needed:
- `id-token: write` for the AWS login job;
- `contents: write` for the deploy job, to push the tag commit.

You don't need to change the repo's default *Workflow permissions* setting.

### 10.5 Your first pipeline run: the pull-request flow

This is how changes reach production in most teams:
branch → PR → checks → merge → deploy.

1. **Pull first.** The pipeline commits to `main`, so always start from the latest:
   ```bash
   cd ~/code/my_infra
   git switch main && git pull --rebase
   git switch -c feature/hello-pipeline
   ```
2. **Make a visible change:** bump the version to `0.2.0` in
   `example-app/pom.xml` (the `<version>` right under `<artifactId>example-app`).
   Run the tests (`docker build --provenance=false -t t example-app`): one
   **fails**, because `AppTest.infoReportsAppNameAndVersion` expects `0.1.0`.
   Update it to `0.2.0`. That's the test doing its job.
3. **Push the branch and open a PR:**
   ```bash
   git commit -am "example-app: version 0.2.0"
   git push -u origin feature/hello-pipeline
   gh pr create --fill          # or click "Compare & pull request" on github.com
   ```
4. **Watch job 1 on the PR** (*Checks* tab, or `gh pr checks --watch`). After a
   few minutes **SonarQube Cloud comments on the PR** with the quality gate
   result. A red check means don't merge.
5. **Merge** (`gh pr merge --squash --delete-branch`, or the button). The
   push to `main` starts the full run: *Actions* tab → **example-app CI/CD**.
   Watch all three jobs go green. The run **Summary** shows the SonarQube
   link, the ECR scan counts and the deployed tag.
6. **See the deploy commit** that the pipeline pushed:
   ```bash
   git switch main && git pull --rebase
   git log --oneline -3          # top: "deploy(example-app): 1a2b3c4 [skip ci]" by github-actions[bot]
   ```
7. **Watch ArgoCD roll it out** (within ~3 minutes, or click *Refresh* in the UI):
   ```bash
   kubectl get application example-app -n argocd -w
   ALB=$(kubectl get ingress public -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   watch -n2 "curl -s http://$ALB/ | jq -c '{version, commit, pod}'"
   ```
   `version` becomes `0.2.0` and `commit` the new short SHA (matching `git
   log`). The commit you merged is now running in EKS, with no manual step after
   the merge.

Note that the deploy commit doesn't trigger another run: its message has
`[skip ci]`, it only changes `example-app/k8s/**` (excluded from the
triggers), and pushes made with the built-in `GITHUB_TOKEN` never start new runs.

### 10.6 Where to look

| What | Where |
|---|---|
| Pipeline runs, logs, test reports (artifact) | github.com → *Actions* → **example-app CI/CD** |
| Code quality, coverage, quality gate history | sonarcloud.io → your project |
| Images and their scan results | AWS console → ECR → `example-app`, or `aws ecr describe-images --repository-name example-app` |
| What's deployed, deploy history, diffs | ArgoCD UI → `example-app` → *History and rollback* |
| What's running | `curl http://$ALB/` → `commit` |

### 10.7 Break it on purpose (the best way to learn the gates)

| Try this | What happens |
|---|---|
| Make a unit test fail (e.g. change an expected value in `AppTest.java`) and push to a PR | Job 1 fails at `mvn verify`. The PR shows a red ✗; on `main` nothing is built or deployed. Download the *test-reports* artifact to see why. |
| Add a new endpoint **without a test** | Coverage on new code drops below 80%, so the **quality gate fails**. Job 1 goes red and SonarQube Cloud's PR comment shows which condition failed. |
| Set repo variable `ECR_FAIL_ON_CRITICAL=true` | An image with CRITICAL CVEs is still pushed (immutable, for investigation) but **not deployed**. The run fails at the scan step. |
| Edit `example-app/k8s/configmap.env` only | **No pipeline run** at all: a manifest-only change is pure GitOps, and ArgoCD applies it directly (Phase 9-A). |
| Re-run a successful pipeline (*Re-run all jobs*) | Job 2 sees the tag already exists in ECR, skips the build, and job 3 finds nothing to change. Safe to repeat. |

### 10.8 Roll back

Every deploy is one bot commit, so revert it:

```bash
git pull --rebase
git log --oneline --grep "deploy(example-app)" -3      # find the bad deploy commit
git revert <that-commit> --no-edit && git push
```

ArgoCD redeploys the previous tag. The old image is still in ECR, so nothing
needs rebuilding and no pipeline run happens. Fix the bug, then merge a new PR
to roll forward.

### 10.9 Optional: scan from your machine

Same analysis as job 1, in a throwaway container, handy for debugging Sonar settings:

```bash
cd ~/code/my_infra/example-app
export SONAR_TOKEN=<token>
docker run --rm -e SONAR_TOKEN -v "$PWD":/src -w /src maven:3.9-eclipse-temurin-21 \
  mvn -B verify org.sonarsource.scanner.maven:sonar-maven-plugin:5.8.0.7211:sonar \
    -Dsonar.organization=<org-key> -Dsonar.projectKey=<project-key>
sudo rm -rf target      # the container left root-owned build output behind
```

### 10.10 Dependabot: automatic dependency updates

`.github/dependabot.yml` makes GitHub open PRs every week when **GitHub
Actions**, **Maven dependencies** (Spring Boot…) or **Docker base images**
have updates or security fixes. Each PR runs job 1, so you see whether it still
builds and passes the tests. Merge it, and it deploys like any other change.
That's continuous patching for the app, as Day-2 node rollouts are for the cluster.

(Dependabot PRs can't read repo secrets, so their runs skip the SonarQube scan
with a warning. That's expected.)

## Phase 11 — Service mesh: Istio sidecars, mTLS, Kiali

ArgoCD installed Istio in Phase 6 (waves -6 to -3), and every example-app pod
already runs with an Envoy sidecar. This phase explains what the mesh does
and lets you prove it.

### 11.1 What the mesh adds and where it lives

```
            istiod (control plane, istio-system)
     injects sidecars · issues certificates · pushes routing config
                │                 │                  │
                ▼                 ▼                  ▼
 ALB ─► [ ingress gateway ] ══mTLS══► [ Envoy sidecar │ example-app ]
          (Envoy, istio-ingress)        (same pod, localhost hop)

 istio-cni (DaemonSet on every node): redirects each pod's traffic into its
 sidecar, so pods need no privileged init container.
```

What the app gets **without changing a line of its code**:
- **Encryption and identity:** every hop is mutual TLS. Each workload's
  certificate encodes its service account, e.g.
  `cluster.local/ns/istio-ingress/sa/istio-ingressgateway`.
- **Authorization by identity:** "only the gateway may call example-app",
  enforced by the sidecar.
- **Traffic control:** timeouts, retries, fault injection, canary splits, all
  as YAML in Git.
- **Uniform telemetry:** request rate, errors and latency for every call, plus
  Envoy access logs.

| File | What it does |
|---|---|
| `infra/kubernetes/apps/templates/istio.yaml` | ArgoCD Applications: istio-base (CRDs), istio-cni, istiod, istio-ingressgateway |
| `infra/kubernetes/platform/istio/peer-authentication.yaml` | **STRICT mTLS** mesh-wide |
| `infra/kubernetes/platform/istio-ingress/` | the gateway listener + the ALB Ingress in front of it |
| `example-app/k8s/virtualservice.yaml` | the app's route on the gateway, with timeout and retries |
| `example-app/k8s/authorizationpolicy.yaml` | only the gateway's identity may call port 8080 |
| `example-app/k8s/deployment.yaml` | annotation that keeps the management port 8081 outside the sidecar (probes, Prometheus) |
| `example-app/k8s/hpa.yaml` | scales on the **app container's** CPU, ignoring the sidecar's |
| `infra/kubernetes/monitoring/config/istio-monitors.yaml` | Prometheus scrapes every Envoy and istiod |
| `infra/kubernetes/apps/templates/kiali.yaml` | Kiali, the mesh console |

🧠 **The trade-off:** a sidecar costs ~64 MiB of memory and a little CPU per pod.
Each call gets two extra Envoy hops (gateway and sidecar, typically ~1–3 ms),
and there are more moving parts to understand. Istio's *ambient mode* removes
the per-pod sidecars. You're using sidecars here because they're the most
common setup in production, and the easiest to see working.

### 11.2 See the sidecars

```bash
kubectl get pods -n example-app                 # READY 2/2: app + Envoy
POD=$(kubectl get pod -n example-app -l app.kubernetes.io/name=example-app -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $POD -n example-app -o jsonpath='{range .spec.initContainers[*]}{.name} restartPolicy={.restartPolicy}{"\n"}{end}'
istioctl proxy-status                           # every proxy SYNCED with istiod
istioctl analyze -A                             # config problems? Expect only "Info [IST0102]" notes (below)
```

🧠 What you're looking at:
- **`istio-proxy` is listed under `initContainers` with `restartPolicy=Always`.**
  That's a Kubernetes *native sidecar*: it starts before the app and stops
  after it, so no requests are lost at startup or shutdown.
- **`istio-validation`** checks that the CNI agent set up the traffic
  redirection. It runs unprivileged, which is why the namespace can keep Pod
  Security `restricted`.
- **The sidecar isn't in Git.** istiod's webhook adds it when each pod is
  created. ArgoCD compares the *Deployment* (one container) with Git, so
  there's no drift.
- **`IST0102` from `istioctl analyze`** just means "this namespace isn't
  labelled for injection" (`default`, `istio-ingress`, ...). That's expected.
  The gateway gets its proxy from its own chart, so don't label `istio-ingress`.
  Treat *Warning* and *Error* lines as real problems.

### 11.3 Prove mTLS and zero-trust

**From outside the mesh**, a pod without a sidecar speaks plain HTTP:

```bash
kubectl run plain --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://example-app.example-app/
```

**Expect `000`** (curl exit code 56, connection reset): the sidecar only accepts mutual TLS.

**From inside the mesh, but not allowed:**

```bash
kubectl create ns mesh-test && kubectl label ns mesh-test istio-injection=enabled
kubectl run curl -n mesh-test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -m 5 -w ' -> HTTP %{http_code}\n' http://example-app.example-app/
kubectl delete ns mesh-test
```

**Expect `RBAC: access denied -> HTTP 403`.** The connection is encrypted and
authenticated, but the AuthorizationPolicy only admits the gateway's identity.

**Through the front door:** `curl http://$ALB/` works. The gateway's identity
is the allowed one.

Also look at Grafana → *Example App* → **Mesh: mTLS-encrypted share**. It should read **100%**.

🧠 This is **zero trust** inside the cluster. Being on the network (any pod
can reach any pod IP) grants nothing: every caller needs a valid identity
*and* a policy that allows it. Compare that with security groups, which only
know IP addresses.

### 11.4 Kiali: watch the mesh live

```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
```

Open **http://localhost:20001** → *Traffic Graph* → select namespaces
`example-app` and `istio-ingress`. In another terminal, generate traffic
(same loop as Phase 8.3, mixing good requests and errors).

- *Display* → tick **Security**: a padlock on the gateway → example-app edge means mTLS.
- Click the edge: requests/sec, error %, response times.
- *Istio Config*: Kiali validates the Gateway, VirtualService and
  AuthorizationPolicy. Try breaking one in a branch and see it flag it.

Kiali runs **view-only**. Mesh changes go through Git, like everything else.

### 11.5 Envoy access logs

```bash
kubectl logs -n istio-ingress deploy/istio-ingressgateway --tail=5
kubectl logs -n example-app $POD -c istio-proxy --tail=5
```

Each line shows the method, path, response code, **response flags**, upstream
pod and timings. Envoy writes access logs in batches, so a request can take
up to ~10 s to appear. A denied call shows `403 ... rbac_access_denied_matched_policy[none]`.
Common flags:
- `-`: normal;
- `UF`: couldn't connect upstream;
- `URX`: retries exhausted;
- `DI` / `FI`: fault injected (next section).

### 11.6 Traffic management: inject faults through Git

Make the gateway delay half of all requests by 2 seconds, without touching
the app. In `example-app/k8s/virtualservice.yaml`, add a `fault` block to the
route (same indentation as `route:`):

```yaml
  http:
    - name: default
      fault:
        delay:
          percentage: { value: 50 }
          fixedDelay: 2s
      route:
        ...
```

```bash
git commit -am "chaos: delay 50% of example-app requests" && git push
# manifest-only change -> no CI run; ArgoCD applies it within ~3 min
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{time_total}s\n' http://$ALB/; done
```

About half the requests take ~2 s, and the gateway logs show flag `DI`.
Notice the app's own *p95 latency* panel **doesn't move**: the delay happens in
the gateway, before the request reaches the app. *Where* you measure decides
what you see. (CloudWatch's ALB `TargetResponseTime` in Phase 8.4 does see it.)

Now try `abort` instead of `delay` (`abort: { percentage: { value: 20 }, httpStatus: 503 }`):
20% of requests get 503 with flag `FI`, and the app never even sees them.

Clean up with `git revert HEAD --no-edit && git push`.

🧠 **Timeouts and retries** are in the same file: `timeout: 10s`, and 2 retries
only when the request never reached the app (connection refused or reset).
Retrying a 500 would hide real errors and multiply the load on a struggling
service. For an experiment, set `timeout: 2s` and call `/api/slow?ms=4000`:
the gateway answers `504 upstream request timeout`.

### 11.7 What Istio costs

| | Cost |
|---|---|
| Istio, Kiali | **$0**: open source, no licence |
| New AWS resources | **None.** Still one ALB (it now fronts the gateway instead of the app) |
| Capacity on your nodes | ~8 more pods (istio-cni ×3, istiod, gateway ×2, Kiali), plus one Envoy container per app pod (no extra pod IP). About +0.5 vCPU and +1 GiB of memory requested, and ~39 of 51 pod slots used. **Fits on 3 × t3.medium** |
| Images pulled through the NAT (~300 MB, once) | ~$0.01 |
| Prometheus storage | more series (Envoy metrics), well within the 20 GiB volume |

So it adds **nothing** to your ~$8.50/day unless you need a 4th node: if
autoscaling to 6 app pods plus your experiments hits *Too many pods*, set
`node_desired_size = 4` (≈ +$1/day).

---

## Day-2 operations: patching and upgrades

| What | How |
|---|---|
| **EKS node OS patches** | AWS publishes a new node AMI regularly. Roll nodes onto it, one at a time, respecting PodDisruptionBudgets: `aws eks update-nodegroup-version --cluster-name devops-lab-eks --nodegroup-name default`. Check with `aws eks describe-nodegroup --cluster-name devops-lab-eks --nodegroup-name default --query nodegroup.releaseVersion` |
| **Kubernetes upgrade** | Read the [EKS release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html), set `kubernetes_version` one minor version up (e.g. `"1.37"`) in `terraform.tfvars`, then `terraform apply`. The control plane upgrades first, then the add-ons move to that version's defaults, then nodes roll. Never skip a minor version. |
| **Platform charts** | Bump a version in `infra/kubernetes/apps/values.yaml`, push. ArgoCD upgrades it. |
| **ArgoCD itself** | Bump `argocd_chart_version` in `infra/ansible/vars/gitops.yml`, re-run `ansible-playbook argocd-bootstrap.yml`. |
| **Istio** | Check the [supported releases](https://istio.io/latest/docs/releases/supported-releases/) for your Kubernetes version. Bump `versions.istio` in `infra/kubernetes/apps/values.yaml` **one minor version at a time** and push: ArgoCD upgrades base, CNI, istiod and the gateway. Running sidecars keep the old version until their pods restart, so run `kubectl rollout restart deploy/example-app -n example-app` (or just deploy). `istioctl proxy-status` shows each proxy's version. Bump `versions.kiali` to a release tested with the new Istio. (Production does *revision-based canary* upgrades: two istiods side by side.) |
| **App dependencies and base images** | Dependabot opens weekly PRs (Phase 10.10). Review the CI result, merge, and the pipeline deploys it. |

🧠 **Pets vs cattle:** EKS nodes are *cattle*. They're never patched in place,
just **replaced** by fresh nodes from a newer image. A long-lived server you
log into and patch would be a *pet*. This platform deliberately has no pets:
build tools are SaaS (GitHub, SonarQube Cloud), and everything else is
replaceable from code.

---

## Costs and teardown

### Approximate cost (us-east-1, on-demand)

| Item | $/hour | ~$/month |
|---|---|---|
| EKS control plane | 0.10 | 73 |
| 3 × t3.medium nodes, on-demand (+ 120 GB gp3) | 0.138 | 101 |
| NAT gateway (+ data processing) | 0.045 | 33+ |
| ALB (+ LCUs) | 0.023 | 17+ |
| Public IPv4 addresses (NAT + ALB) | ~0.02 | ~15 |
| EBS for Prometheus/Alertmanager, KMS, CloudWatch, ECR, S3 | — | ~8 |
| **Total** | **~0.36 (≈ $8.50/day)** | **~$250** |
| GitHub Actions + SonarQube Cloud (free plans) | 0 | 0 |
| Istio + Kiali (open source, on the existing nodes; see Phase 11.7) | 0 | 0 |

None of this is covered by the AWS free tier. That covers ~750 hours/month
of a micro instance (one machine). The EKS control plane, NAT gateway and ALB
are always billed, and micro instances can't run this cluster anyway (Phase 3.4).

Set an **AWS Budgets** alert (e.g. $20/month; the first two budgets are free)
so a forgotten cluster emails you instead of quietly billing.

Ways to save:
- **Destroy when not practising.** Everything is code, so rebuilding takes
  about 30 minutes. A 4-hour session costs about $1.50.
- Run `terraform destroy` on the VPC too if you're stopping for days. The NAT gateway alone is ~$1/day.

### Teardown — order matters

The controller created the ALB and the EBS CSI driver created the volumes.
Terraform doesn't know they exist. Delete them **through Kubernetes first**, or
they're orphaned and keep billing. An orphaned ALB will also block the VPC deletion.

```bash
# 1. Stop the root app from re-creating children while you delete them
kubectl patch application root -n argocd --type merge -p '{"spec":{"syncPolicy":null}}'

# 2. Delete the ALB: it belongs to the Istio ingress gateway's Ingress
kubectl delete application istio-ingressgateway -n argocd
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'   # repeat until devops-lab-public is gone

# 3. Delete monitoring, then its volumes (StatefulSet PVCs are kept by design)
kubectl delete application kube-prometheus-stack monitoring-config -n argocd
kubectl delete pvc --all -n monitoring
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'   # until empty

# 4. Everything else (cascades to remaining apps)
kubectl delete application root -n argocd

# 5. Terraform, in reverse order
cd ~/code/my_infra/infra/terraform/tooling && terraform destroy
cd ../eks && terraform destroy
cd ~/code/my_infra/aws_vpc && terraform destroy              # optional: only if you're done for a while
cd ~/code/my_infra/infra/terraform/bootstrap && terraform destroy   # LAST, and only if all others are destroyed
```

SonarQube Cloud and GitHub cost nothing idle, so leave them. While the AWS side
is torn down, though, a merge to `main` fails at the AWS login step, because
the OIDC role is gone. To avoid red runs, disable the workflow (*Actions* →
**example-app CI/CD** → *⋯* → *Disable workflow*) and re-enable it after
rebuilding. After a rebuild, also re-set the `AWS_ROLE_ARN` variable if the
account changed.

**Leftover check:**

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]'
aws logs describe-log-groups --log-group-name-prefix /aws/eks --query 'logGroups[].logGroupName'
```

---

## Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| `terraform init`: "bucket" required / backend errors | Run from the stack folder with `-backend-config=../backend.hcl` (VPC: `../infra/terraform/backend.hcl`). Did Phase 1 run? |
| `init -migrate-state` prints **"Warning: Missing backend configuration"** and nothing moves | The `backend "s3"` block in `aws_vpc/versions.tf` is still commented out, so Terraform ignores `-backend-config` and stays local. Uncomment it (Phase 2.1) and re-run. |
| `kubectl` hangs / i/o timeout | Your public IP changed. Update `cluster_endpoint_public_access_cidrs`, `terraform apply`. |
| `kubectl`: "You must be logged in to the server" | You're using a different AWS identity than the one that created the cluster. Check `aws sts get-caller-identity`, or add your ARN to `cluster_admin_principal_arns`. |
| Ansible: "ansible.cfg in world writable directory" | You're under `/mnt/c/...`. Work in `~/code/my_infra` (step 1.4). |
| `argocd-bootstrap.yml` fails reading Terraform outputs | The EKS stack isn't applied, or `terraform init` wasn't run in `infra/terraform/eks` on this machine. |
| App stuck `Unknown` / `ComparisonError` in ArgoCD | Wrong `gitops_repo_url`, or a private repo without `GITOPS_REPO_TOKEN`. Check with `kubectl -n argocd describe application root`. |
| example-app pods `ImagePullBackOff` | `ACCOUNT_ID` not replaced in `kustomization.yaml`, or that tag was never pushed. Check `aws ecr list-images --repository-name example-app`. |
| Ingress has no ADDRESS | It's `kubectl get ingress public -n istio-ingress`. Check `kubectl logs -n kube-system deploy/aws-load-balancer-controller`. Usually missing subnet tags (Phase 2.2) or the controller isn't Healthy yet. |
| example-app pods `READY 1/1` (no sidecar) | The namespace lacks `istio-injection=enabled` (`kubectl get ns example-app --show-labels`), or the pods were created before istiod was ready. Fix: `kubectl rollout restart deploy/example-app -n example-app`. |
| Pods rejected: `violates PodSecurity "restricted"` mentioning `istio-init` / `NET_ADMIN` | The injector doesn't know the CNI agent is on. Check that the istiod values have `pilot.cni.enabled: true` and that `istio-cni` pods run on every node: `kubectl get ds -n istio-system`. |
| `curl http://$ALB/` → **404** | No VirtualService matched. Run `istioctl analyze -A`, and check that `gateways: [istio-ingress/public-gateway]` is in `virtualservice.yaml`. |
| `curl http://$ALB/` → **503** `no healthy upstream` / `upstream connect error` | No ready app pods (`kubectl get pods -n example-app`), or the sidecar isn't synced (`istioctl proxy-status`). |
| `curl http://$ALB/` → **403** `RBAC: access denied` | The AuthorizationPolicy principal doesn't match the gateway's service account (`cluster.local/ns/istio-ingress/sa/istio-ingressgateway`). |
| ALB target group: targets **unhealthy** | The ALB checks gateway port 15021 `/healthz/ready`. Look at `kubectl get pods -n istio-ingress` and the controller logs. |
| ArgoCD: `istiod` / `istio-base` `OutOfSync` on webhook configurations | istiod patches its own webhooks at runtime. `ignoreDifferences` covers the known fields, so click *Sync* once. If it persists, check the diff for a new field and add it in `templates/istio.yaml`. |
| Kiali graph is empty | It shows recent traffic only, so generate some. Check Prometheus → *Targets* → `envoy-stats-monitor` is UP. |
| Prometheus/Alertmanager pods `Pending`, PVC `Pending` | The StorageClass or EBS CSI driver isn't ready. Check `kubectl get sc` (gp3 default?), `kubectl get pods -n kube-system -l app=ebs-csi-controller`. |
| Pods `Pending`: "Too many pods" | t3.medium fits 17 pods/node. Raise `node_desired_size` (and `node_min_size`) to 4. |
| Grafana CloudWatch: "no valid credentials" | Service account must be `monitoring/grafana` (matches Terraform). Restart Grafana: `kubectl rollout restart deploy/kube-prometheus-stack-grafana -n monitoring`. |
| kube-prometheus-stack shows `OutOfSync` but `Healthy` | Usually harmless field ordering. Click *Sync*. If it persists, check the diff in the UI. |
| Sonar: "You are running CI analysis while Automatic Analysis is enabled" | Turn Automatic Analysis off (Phase 10.3 step 4). |
| Sonar: "Not authorized" / "Project not found" | Wrong `sonar.organization`/`sonar.projectKey`, or `SONAR_TOKEN` not set/expired. Keys are case-sensitive. |
| Sonar shows 0% coverage | Run `mvn verify` (not just `package`) in the same command as the scan; the JaCoCo report is generated in `verify`. |
| Pipeline: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token's claims don't match the role's trust policy. Check `github_repository` in the tooling stack matches GitHub **exactly** (case-sensitive), the run is on `main`, and `AWS_ROLE_ARN` is the current role. PR runs never get AWS access, by design. |
| Pipeline: `Could not load credentials` / `id-token` errors | The job lacks `permissions: id-token: write`, or `AWS_ROLE_ARN` / `AWS_REGION` variables are missing. |
| Deploy job: `Permission to ... denied to github-actions[bot]` / `protected branch` | A branch rule blocks pushes to `main`. Let GitHub Actions bypass it, or see *Pipeline hardening* in What's next. |
| Pipeline didn't run at all | Only changes under `example-app/` (except `k8s/` and `*.md`) or to the workflow file trigger it, and `[skip ci]` commits never do. Use *Run workflow* (manual trigger) to force a run. |
| Your `git push` is rejected (`fetch first` / non-fast-forward) | The pipeline pushed a deploy commit to `main` after your last pull. Run `git pull --rebase` and push again. |
| `tag invalid: The image tag '...' already exists` | Immutable tags. The pipeline skips existing tags automatically, so this only happens with manual pushes: use a new tag. |

Handy commands: `kubectl get events -A --sort-by=.lastTimestamp | tail -30`,
`kubectl describe pod <pod> -n <ns>`, `kubectl logs <pod> -n <ns> --previous`.

---

## What's next

**Pipeline hardening** (once the basic flow from Phase 10 feels familiar):
- **Protect `main`:** a GitHub ruleset requiring a PR and a passing
  *Build, test & scan* check. The deploy job pushes to `main`, so either allow
  it to bypass the rule, or switch to a deploy key / GitHub App for that push.
- **Pin actions to commit SHAs** instead of `@v7` tags (Dependabot keeps them
  updated), so a hijacked tag can't run code in your pipeline.
- **Environments with approval:** add a `staging` overlay + ArgoCD app, and a
  `production` GitHub environment that needs a manual approval before the tag bump.
- **Sign images** (cosign) and generate an SBOM. Verify signatures in the
  cluster with an admission policy.
- **Instant deploys:** a GitHub webhook to ArgoCD. That needs the ArgoCD server
  reachable from the internet (an Ingress with auth), so it's a security trade-off.

**Service mesh next steps** (Phase 11 builds the base):
- **Canary releases:** run v1 and v2 side by side and shift 10% → 50% → 100%
  with VirtualService weights, or automate it with Argo Rollouts.
- **Egress control:** `outboundTrafficPolicy: REGISTRY_ONLY` + `ServiceEntry`,
  so pods can only call destinations you allow.
- **Distributed tracing:** OpenTelemetry + Jaeger/Tempo, to see one request across services.
- **Kubernetes Gateway API** instead of Istio's Gateway/VirtualService: the newer standard.
- **Ambient mode:** compare Istio without sidecars.

**Platform hardening backlog** (great practice, roughly easiest first):
- `http_put_response_hop_limit = 1` on nodes: pods can't reach the node's IAM role.
- Alertmanager receiver (Slack or email), so alerts reach you.
- HTTPS on the ALB: a domain in Route 53 + ACM certificate (annotations are commented in `ingress.yaml`).
- NetworkPolicies: already enforced by the VPC CNI (`enableNetworkPolicy`). Write a default-deny for `example-app`.
- External Secrets Operator + AWS Secrets Manager instead of bootstrap-created secrets.
- Private-only EKS API endpoint + VPN / SSM-based access.
- Karpenter for node autoscaling; one NAT gateway per AZ.
- Split `example-app` into its own Git repository (ArgoCD just needs a second `repoURL`).

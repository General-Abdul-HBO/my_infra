# Deployment Guide — EKS + ArgoCD + Prometheus/Grafana on AWS

This guide takes you from the VPC you already have to a running platform:

- an EKS cluster whose worker nodes sit in **private subnets**
- ArgoCD continuously deploying from Git (GitOps)
- an example Spring Boot app behind an AWS load balancer
- Prometheus, Grafana and Alertmanager monitoring it
- preparation for CI/CD with **GitHub Actions** (on github.com) and the
  free plan of **SonarQube Cloud** for code scanning

Every phase ends with a **Verify** step, and the boxes marked 🧠 explain *why*
things are done this way. Don't skip those: understanding them is the point.

> The CI/CD pipeline itself is built in the next phase. Until then you do by
> hand what the pipeline will automate (build → push → bump tag → ArgoCD
> deploys), so you'll understand exactly what the pipeline does.

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
12. [Phase 10 — Get ready for CI/CD: SonarQube Cloud + GitHub Actions](#phase-10--get-ready-for-cicd-sonarqube-cloud--github-actions)
13. [Day-2 operations](#day-2-operations-patching-and-upgrades)
14. [Costs and teardown](#costs-and-teardown)
15. [Troubleshooting](#troubleshooting)
16. [What's next](#whats-next)

---

## 0. The big picture

```
                                   Internet
                                       │
              ┌────────────────────────┼─────────────────────────────────┐
              │ VPC "main" 10.0.0.0/16 │  (3 availability zones)          │
              │                        ▼                                  │
  PUBLIC      │   Internet Gateway ◄── ALB (example-app)    NAT Gateway ──┼──► internet:
  10.0.1-3.0  │                         │                    ▲  (1 EIP)  │    OS patches,
              │                         │                    │           │    image pulls,
              │ ────────────────────────┼────────────────────┼────────── │    GitHub
  PRIVATE     │                         ▼                    │           │
  10.0.4-6.0  │   EKS worker nodes (no public IPs) ──────────┘           │
              │     pods get VPC IPs; the ALB targets pod IPs directly    │
              └───────────────────────────────────────────────────────────┘

  You ──HTTPS (your IP only)──► EKS API endpoint      (kubectl, helm, Ansible)
  ArgoCD (in EKS) ──polls──► your repo on github.com  (via the NAT gateway)

  Next phase (SaaS, nothing to host):
  git push ─► GitHub Actions ─► SonarQube Cloud (scan) ─► ECR (image) ─► Git (new tag) ─► ArgoCD
```

**Who does what**

| Tool | Responsibility | Lives in |
|---|---|---|
| Terraform | AWS resources: VPC, EKS, IAM, ECR, S3 | `aws_vpc/`, `infra/terraform/` |
| Ansible | One-time cluster bootstrap: installs ArgoCD and hands the cluster over to Git | `infra/ansible/` |
| ArgoCD | Everything *inside* Kubernetes, continuously synced from Git | `infra/kubernetes/`, `example-app/k8s/` |
| Prometheus / Grafana | Metrics, dashboards, alerts | `infra/kubernetes/monitoring/` |
| GitHub Actions + SonarQube Cloud *(next phase)* | Build, test, scan, push the image, bump the tag | `.github/workflows/` (to be created) |

🧠 **Why split it like this?** Each tool does the job it's best at. Terraform
creates cloud resources. Ansible runs a sequence of setup steps (here: install
ArgoCD, create secrets, hand over). ArgoCD keeps the cluster matching Git and
undoes manual drift. CI builds and checks code. If something is wrong, you
know which layer to look at.

**Terraform stacks and order** (each has its own state file):

```
bootstrap (state bucket) → aws_vpc → eks → tooling (ECR)
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
  scripts into CRLF (`$'\r': command not found`).

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
(It's also where GitHub Actions will run in the CI/CD phase.)

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

For HTTPS push auth use a [personal access token](https://github.com/settings/tokens)
as the password, or install GitHub CLI and run `gh auth login`.

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

This creates the **ECR repository `example-app`**:
- **immutable tags:** a pushed tag can never be overwritten;
- **scan on push:** basic CVE scan of every image;
- **lifecycle policy:** untagged images expire after 7 days, and only the newest 30 are kept.

🧠 The stack is called *tooling* because it holds what build and deploy
tooling needs. In the CI/CD phase it also gets the GitHub Actions → AWS
**OIDC** role (Phase 10.4), so CI can push images without any stored AWS keys.

**Verify:** `aws ecr describe-repositories --query 'repositories[].repositoryUri'`

---

## Phase 5 — Build and push the app image

```bash
cd ~/code/my_infra/example-app
docker build -t example-app:0.1.0 .        # compiles, runs 5 unit tests, builds the image
```

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

Edit `infra/ansible/vars/gitops.yml` and set `gitops_repo_url` to your HTTPS
clone URL, e.g. `https://github.com/<your-user>/my_infra.git`. Commit and push.

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
| -5 | platform-storage | default `gp3` StorageClass |
| -4 | aws-load-balancer-controller, metrics-server | ALB controller, resource metrics |
| -2 | kube-prometheus-stack | Prometheus, Alertmanager, Grafana, exporters |
| -1 | monitoring-config | example-app dashboard, CloudWatch data source |
| 0 | example-app | your app |

The end state is every app `Synced` and `Healthy`.

🧠 **App-of-apps:** you created one Application by hand, and everything else
is *declared in Git* as more Applications. Adding a component to the cluster
means adding a file under `infra/kubernetes/apps/templates/` and pushing.

🧠 **Sync waves:** the example app's Ingress needs the load balancer
controller's webhook, and its ServiceMonitor needs the Prometheus CRDs. Waves
plus the Application health check in `argocd/values.yaml` make ArgoCD wait for
each wave to be **Healthy** before starting the next.

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
kubectl get pods -n example-app -o wide        # 2 pods, ideally in different AZs/nodes
kubectl get ingress -n example-app             # ADDRESS appears after ~2 min
ALB=$(kubectl get ingress example-app -n example-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
```

DNS for a new ALB takes 1–3 minutes. Then:

```bash
curl -s http://$ALB/ | jq                      # version, environment, pod
curl -s "http://$ALB/api/greeting?name=Abdul"  # greeting comes from the ConfigMap
for i in 1 2 3 4 5 6; do curl -s http://$ALB/ | jq -r .pod; done   # load balanced across pods
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/actuator/prometheus   # 404 - actuator isn't public
```

🧠 **The traffic path:** internet → ALB (public subnets) → **pod IP** (private
subnets). Pod security group rules are managed by the controller.

**Readiness gates:** `kubectl get pods -n example-app -o wide` shows a
`READINESS GATES 1/1` column. A new pod only counts as Ready once **the ALB's
health check** passes, so rolling updates never send traffic to a pod the ALB
isn't ready for.

**Pod Security `restricted`:** the namespace rejects pods that run as root,
add capabilities, etc. The app's `securityContext` is written to pass.

🔒 **Optional:** lock the ALB to your IP by uncommenting `inbound-cidrs` in
`example-app/k8s/ingress.yaml`, then push. ArgoCD applies it.

---

## Phase 8 — Monitoring

### 8.1 Grafana

```bash
cat ~/.devops-lab/grafana-admin-password; echo
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open **http://localhost:3000** and log in as `admin`. Then explore:
- **Dashboards → Applications → Example App**: request rate, error rate, p95
  latency, JVM heap, CPU/memory against the limit, HPA replicas, restarts.
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
ALB=$(kubectl get ingress example-app -n example-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
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

### B. Ship a new version (exactly what CI/CD will automate)

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

## Phase 10 — Get ready for CI/CD: SonarQube Cloud + GitHub Actions

The pipeline itself is the next phase. Everything here is **free**, takes about
20 minutes, and can be done now so the pipeline phase is only about the workflow.

### 10.1 How the pieces fit

```
 git push to main (example-app/**)
        │
        ▼
 GitHub Actions  ── runs on a GitHub-hosted runner (ubuntu-latest), provided
        │           by github.com - nothing for you to install or patch
        ├─ 1. mvn verify            tests + JaCoCo coverage report
        ├─ 2. SonarQube Cloud scan  bugs, vulnerabilities, code smells, coverage
        │                           → quality gate: fail the pipeline if it fails
        ├─ 3. docker build + push   to ECR, tagged with the commit SHA
        │      (AWS login via OIDC - no AWS keys stored in GitHub)
        └─ 4. commit newTag         to example-app/k8s/kustomization.yaml
                                            │
                                            ▼
                         ArgoCD (Phase 6) sees the commit → rolling update
```

That's Phase 9-B, automated. These are the same steps 1–10 as the CI/CD flow
in your reference picture.

🧠 **Words that sound alike:**
- **GitHub (github.com)** is where your repo lives. That's what you're using.
  (*GitHub Enterprise Server* is the self-installed version. Not used here.)
- **GitHub-hosted runners** are the machines GitHub provides to run Actions
  jobs: standard GitHub Actions, and what you'll use. (*Self-hosted runners*
  are machines you'd run yourself. Not needed.)
- **SonarQube Cloud** (sonarcloud.io, formerly SonarCloud) is Sonar's hosted
  service. (*SonarQube Server* is the self-installed version. Not used here.)

### 10.2 What's free

| Service | Free for | Notes |
|---|---|---|
| GitHub Actions (GitHub-hosted runners) | **public repos**: free standard runners | **private repos** on GitHub Free: a monthly allowance of minutes (2,000 at the time of writing; check *Settings → Billing*) |
| SonarQube Cloud **Free plan** | **public repos** | **private projects up to 50,000 lines of code**; no credit card |

This app is a few hundred lines, far under the limit. Only `example-app` (the
Java code) will be scanned, not the Terraform or YAML.

### 10.3 Set up SonarQube Cloud (do this now)

1. Go to **https://sonarcloud.io** → **Log in with GitHub**.
2. **Create an organization** → *Import an organization from GitHub* → pick
   your personal account. When the **SonarQube Cloud GitHub App** install
   screen appears, choose **Only select repositories → `my_infra`**, which is
   least privilege. Pick the **Free** plan.
   Note the **organization key** (e.g. `abdul-github`).
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

### 10.4 Prepare the GitHub repo (do this now)

Repo → *Settings → Secrets and variables → Actions*:

| Type | Name | Value |
|---|---|---|
| **Secret** | `SONAR_TOKEN` | the token from 10.3 step 5 |
| Variable | `SONAR_ORGANIZATION` | your organization key |
| Variable | `SONAR_PROJECT_KEY` | your project key |
| Variable | `AWS_REGION` | `us-east-1` |

🧠 **Secrets vs variables:** secrets are encrypted and masked in logs. Use them
for anything that grants access. Variables are plain config.

**AWS access for the pipeline (built in the CI/CD phase):** no AWS access keys
go into GitHub. Instead, Terraform in `infra/terraform/tooling` will create:
- an **IAM OIDC identity provider** for `token.actions.githubusercontent.com`;
- an **IAM role** that only workflows from *your* repo's `main` branch can assume,
  allowed only to push to the `example-app` ECR repository.

Each workflow run gets short-lived credentials that expire in about an hour.
Nothing long-lived can leak.

### 10.5 Try a scan from your machine (optional, proves the setup)

Run the same scan the pipeline will run, in a throwaway Maven container:

```bash
cd ~/code/my_infra/example-app
export SONAR_TOKEN=<token from 10.3>
docker run --rm -e SONAR_TOKEN -v "$PWD":/src -w /src maven:3.9-eclipse-temurin-21 \
  mvn -B verify org.sonarsource.scanner.maven:sonar-maven-plugin:sonar \
    -Dsonar.organization=<your-org-key> \
    -Dsonar.projectKey=<your-project-key>
```

Open the project on sonarcloud.io: you'll see bugs, code smells, security
hotspots, **coverage %** (from JaCoCo) and the **quality gate** result.
`pom.xml` already sets `sonar.host.url=https://sonarcloud.io` and the coverage
report path, so the organization and project key are the only extra inputs.

**Then delete the local artifacts** the container left behind (owned by root):
`sudo rm -rf target`

### 10.6 Already in the repo, ready for the pipeline

- `pom.xml`: JaCoCo coverage report, the SonarQube Cloud host URL, and the version the pipeline will tag.
- `Dockerfile`: the build the pipeline will run.
- `example-app/k8s/kustomization.yaml`: the `newTag` line the pipeline will update.
- ArgoCD watching `main`: the deploy half is done.

🧠 **No infinite loop:** the pipeline commits the new tag back to `main`.
Commits pushed with the workflow's built-in `GITHUB_TOKEN` **don't trigger new
workflow runs** (GitHub prevents recursion), and the workflow will only watch
`example-app/**` source paths anyway.

---

## Day-2 operations: patching and upgrades

| What | How |
|---|---|
| **EKS node OS patches** | AWS publishes a new node AMI regularly. Roll nodes onto it, one at a time, respecting PodDisruptionBudgets: `aws eks update-nodegroup-version --cluster-name devops-lab-eks --nodegroup-name default`. Check with `aws eks describe-nodegroup --cluster-name devops-lab-eks --nodegroup-name default --query nodegroup.releaseVersion` |
| **Kubernetes upgrade** | Read the [EKS release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html), set `kubernetes_version` one minor version up (e.g. `"1.37"`) in `terraform.tfvars`, then `terraform apply`. The control plane upgrades first, then the add-ons move to that version's defaults, then nodes roll. Never skip a minor version. |
| **Platform charts** | Bump a version in `infra/kubernetes/apps/values.yaml`, push. ArgoCD upgrades it. |
| **ArgoCD itself** | Bump `argocd_chart_version` in `infra/ansible/vars/gitops.yml`, re-run `ansible-playbook argocd-bootstrap.yml`. |
| **App dependencies** | Bump the Spring Boot parent version in `pom.xml`. In the CI/CD phase, Dependabot can open these PRs for you. |

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

# 2. Delete the app -> its Ingress -> the controller deletes the ALB
kubectl delete application example-app -n argocd
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'   # repeat until example-app is gone

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

SonarQube Cloud and GitHub cost nothing idle, so leave them.

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
| `kubectl` hangs / i/o timeout | Your public IP changed. Update `cluster_endpoint_public_access_cidrs`, `terraform apply`. |
| `kubectl`: "You must be logged in to the server" | You're using a different AWS identity than the one that created the cluster. Check `aws sts get-caller-identity`, or add your ARN to `cluster_admin_principal_arns`. |
| Ansible: "ansible.cfg in world writable directory" | You're under `/mnt/c/...`. Work in `~/code/my_infra` (step 1.4). |
| `argocd-bootstrap.yml` fails reading Terraform outputs | The EKS stack isn't applied, or `terraform init` wasn't run in `infra/terraform/eks` on this machine. |
| App stuck `Unknown` / `ComparisonError` in ArgoCD | Wrong `gitops_repo_url`, or a private repo without `GITOPS_REPO_TOKEN`. Check with `kubectl -n argocd describe application root`. |
| example-app pods `ImagePullBackOff` | `ACCOUNT_ID` not replaced in `kustomization.yaml`, or that tag was never pushed. Check `aws ecr list-images --repository-name example-app`. |
| Ingress has no ADDRESS | Check `kubectl logs -n kube-system deploy/aws-load-balancer-controller`. Usually missing subnet tags (Phase 2.2) or the controller isn't Healthy yet. |
| Prometheus/Alertmanager pods `Pending`, PVC `Pending` | The StorageClass or EBS CSI driver isn't ready. Check `kubectl get sc` (gp3 default?), `kubectl get pods -n kube-system -l app=ebs-csi-controller`. |
| Pods `Pending`: "Too many pods" | t3.medium fits 17 pods/node. Raise `node_desired_size` (and `node_min_size`) to 4. |
| Grafana CloudWatch: "no valid credentials" | Service account must be `monitoring/grafana` (matches Terraform). Restart Grafana: `kubectl rollout restart deploy/kube-prometheus-stack-grafana -n monitoring`. |
| kube-prometheus-stack shows `OutOfSync` but `Healthy` | Usually harmless field ordering. Click *Sync*. If it persists, check the diff in the UI. |
| Sonar: "You are running CI analysis while Automatic Analysis is enabled" | Turn Automatic Analysis off (Phase 10.3 step 4). |
| Sonar: "Not authorized" / "Project not found" | Wrong `sonar.organization`/`sonar.projectKey`, or `SONAR_TOKEN` not set/expired. Keys are case-sensitive. |
| Sonar shows 0% coverage | Run `mvn verify` (not just `package`) in the same command as the scan; the JaCoCo report is generated in `verify`. |

Handy commands: `kubectl get events -A --sort-by=.lastTimestamp | tail -30`,
`kubectl describe pod <pod> -n <ns>`, `kubectl logs <pod> -n <ns> --previous`.

---

## What's next

**CI/CD phase: GitHub Actions + SonarQube Cloud.** Using the setup from
Phase 10, we'll add:
1. Terraform in `infra/terraform/tooling`: the GitHub OIDC provider + the ECR-push role.
2. `.github/workflows/example-app.yml`: `mvn verify` → SonarQube Cloud scan +
   quality gate → Docker build → push to ECR (tag = commit SHA) → commit the new
   `newTag`. ArgoCD then deploys.
3. A pull-request workflow: build + scan on every PR, with SonarQube Cloud
   commenting its results on the PR.
4. Optional: an ArgoCD webhook from GitHub, so deploys start instantly instead of within 3 minutes.

**Hardening backlog** (great practice, roughly easiest first):
- `http_put_response_hop_limit = 1` on nodes: pods can't reach the node's IAM role.
- Alertmanager receiver (Slack or email), so alerts reach you.
- HTTPS on the ALB: a domain in Route 53 + ACM certificate (annotations are commented in `ingress.yaml`).
- NetworkPolicies: already enforced by the VPC CNI (`enableNetworkPolicy`). Write a default-deny for `example-app`.
- External Secrets Operator + AWS Secrets Manager instead of bootstrap-created secrets.
- Private-only EKS API endpoint + VPN / SSM-based access.
- Karpenter for node autoscaling; one NAT gateway per AZ.
- Split `example-app` into its own Git repository (ArgoCD just needs a second `repoURL`).

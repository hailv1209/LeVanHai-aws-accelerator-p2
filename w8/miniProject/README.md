# 🚀 K8s on AWS — Terraform 1-Click

> **Xbrain × AWS Accelerator & Internship Program — Week 8 Mini Project**
> Deploy the Xbrain web app onto a Kubernetes cluster (kind) running on EC2, exposed via AWS ALB — fully automated with a single `terraform apply`.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          INTERNET                               │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP :80
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│              AWS Application Load Balancer (ALB)                │
│         xbrain-k8s-alb.<region>.elb.amazonaws.com              │
│                    Security Group: port 80 open                 │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP :30080
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│          EC2 t3.medium  (Amazon Linux 2023)  us-east-1          │
│          Public IP: <dynamic>                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              kind Cluster: xbrain-cluster                 │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │   K8s Deployment: xbrain-app  (2 replicas)         │  │  │
│  │  │   ┌─────────────────┐  ┌─────────────────┐         │  │  │
│  │  │   │  nginx Pod 1    │  │  nginx Pod 2    │         │  │  │
│  │  │   │  :80            │  │  :80            │         │  │  │
│  │  │   └────────┬────────┘  └────────┬────────┘         │  │  │
│  │  │            └──────────┬──────────┘                  │  │  │
│  │  │   K8s Service: NodePort :30080 → Pod :80            │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
│          Port 30080 (host) ←→ Port 30080 (kind container)       │
└─────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Quick Start — 1-Click Deploy

### Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | ≥ 1.5.0 | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| AWS CLI | configured | `aws configure` |
| OpenSSH | (Windows built-in) | already on Windows 10/11 |

> **Note:** AWS credentials (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`) must be configured. Region: `us-east-1`.

### Step 1 — Generate SSH key (one-time setup)

The SSH key pair is needed for Terraform to SSH into EC2 and run provisioners.

```powershell
# From the miniProject root directory
ssh-keygen -t rsa -b 2048 -f terraform/k8s-ec2-key -N ""
```

> ⚠️ If you already have `terraform/k8s-ec2-key` and `terraform/k8s-ec2-key.pub`, skip this step.

### Step 2 — 1-Click Deploy 🎯

```powershell
# From miniProject root directory
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve
```

That's it! Terraform will:
1. Create EC2, Security Groups, ALB in AWS (~2 min)
2. Bootstrap Docker + kind + kubectl on EC2 via `user_data` (~4 min)
3. SSH into EC2, build Docker image, load into kind (~2 min)
4. Deploy K8s Deployment + Service via Kubernetes provider (~1 min)
5. Register EC2 in ALB Target Group

**Total time: ~10-12 minutes**

### Step 3 — Get the URL

```powershell
terraform -chdir=terraform output alb_url
# Output: http://xbrain-k8s-alb-<hash>.us-east-1.elb.amazonaws.com
```

Open the URL in your browser — the Xbrain × AWS app should be live! 🎉

> ⏳ Wait ~2-3 minutes after apply for ALB health checks to pass.

---

## 🌐 Live Demo — Proof

**ALB URL (live):** `http://xbrain-k8s-alb-1623915.us-east-1.elb.amazonaws.com`

![App running via ALB](./screenshot-alb.png)

> App "Xbrain × AWS Accelerator & Internship Program" confirmed accessible from the Internet via AWS ALB → EC2 NodePort 30080 → kind K8s cluster → nginx Pod.

---

## 🗑️ Destroy (Clean Up)

```powershell
terraform -chdir=terraform destroy -auto-approve
```

All AWS resources will be deleted. No charges after destroy.

---

## 📁 Project Structure

```
miniProject/
├── terraform/                  # Terraform root module
│   ├── main.tf                 # Providers + all resources
│   ├── variables.tf            # Input variables
│   ├── outputs.tf              # Outputs (ALB URL, EC2 IP, SSH command)
│   ├── userdata.sh             # EC2 bootstrap: Docker + kind + kubectl
│   ├── kubeconfig              # Placeholder (overwritten by provisioner)
│   ├── k8s-ec2-key             # SSH private key (git-ignored)
│   └── k8s-ec2-key.pub         # SSH public key (git-ignored)
├── app/                        # Application source
│   ├── Dockerfile              # nginx:alpine serving the Xbrain app
│   ├── index.html              # Xbrain web app
│   ├── style.css               # Styles
│   ├── logo.jpg                # Logo image
│   └── intern.jpg              # Internship image
├── .gitignore
└── README.md
```

---

## 🔌 How Providers Are Wired

### Providers Used (3 total — satisfies ≥2 requirement)

| # | Provider | Purpose |
|---|---|---|
| 1 | `hashicorp/aws` ~5.0 | Creates all AWS infrastructure (EC2, SG, ALB, Key Pair, VPC) |
| 2 | `hashicorp/kubernetes` ~2.27 | Deploys K8s Deployment + Service into the kind cluster |
| 3 | `hashicorp/null` ~3.2 | Bridges AWS and Kubernetes via provisioners |

### Wiring Diagram

```
┌────────────────┐     public_key      ┌────────────────┐
│  aws_key_pair  │ ←───────────────── │  k8s-ec2-key   │
│  (AWS prov.)   │                    │  .pub (local)  │
└────────────────┘                    └────────────────┘

┌────────────────┐   instance_id +     ┌─────────────────────┐
│  aws_instance  │ ──────────────────→ │  null_resource      │
│  (AWS prov.)   │   public_ip         │  .k8s_setup         │
└────────────────┘                     │  (null prov.)       │
                                       │                     │
                                       │  [file provisioner] │
                                       │  → copies app/ → EC2│
                                       │                     │
                                       │  [remote-exec]      │
                                       │  → docker build     │
                                       │  → kind load image  │
                                       │  → export kubeconfig│
                                       │                     │
                                       │  [local-exec]       │
                                       │  → SCP kubeconfig   │
                                       │    to ./kubeconfig  │
                                       └──────────┬──────────┘
                                                  │
                                        writes ./kubeconfig
                                                  │
                                                  ▼
                                       ┌─────────────────────┐
                                       │  kubernetes provider │
                                       │  config_path =      │
                                       │  ./kubeconfig       │
                                       └──────────┬──────────┘
                                                  │
                              ┌───────────────────┴──────────────────┐
                              ▼                                       ▼
                   ┌─────────────────────┐             ┌─────────────────────┐
                   │ kubernetes_deployment│             │  kubernetes_service  │
                   │ xbrain-app (2 pods) │             │  NodePort :30080     │
                   └─────────────────────┘             └─────────────────────┘

┌──────────────────┐   target_id =      ┌─────────────────────┐
│  aws_lb_target   │ ←─────────────────  │  aws_instance.id    │
│  _group_attachment│  EC2 instance ID   │  port 30080         │
└──────────────────┘                    └─────────────────────┘
```

### Why This Wiring Approach?

**Problem:** Terraform's Kubernetes provider needs to know the K8s API server URL and TLS certificates *before* the cluster exists. Provider configs cannot reference computed resource values.

**Solution (standard pattern):**
1. A **placeholder** `./kubeconfig` file exists in the repo (empty/valid but unusable)
2. The **kubernetes provider** is configured with `config_path = "./kubeconfig"`
3. A **null_resource** with `remote-exec` + `local-exec` provisioners runs AFTER EC2 is up and overwrites `./kubeconfig` with the real kind cluster kubeconfig (server URL = EC2 public IP)
4. All `kubernetes_*` resources use `depends_on = [null_resource.k8s_setup]`, ensuring they are only created AFTER the real kubeconfig is in place

This is the **de-facto standard** for bootstrapping Kubernetes clusters with Terraform when the cluster is created as part of the same apply.

---

## 🔧 Variables

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `project_name` | `xbrain-k8s` | Resource name prefix |
| `instance_type` | `t3.medium` | EC2 instance type |
| `ssh_public_key_path` | `./k8s-ec2-key.pub` | Path to SSH public key |
| `ssh_private_key_path` | `./k8s-ec2-key` | Path to SSH private key |

To override:
```powershell
terraform -chdir=terraform apply -auto-approve -var="instance_type=t3.large"
```

---

## 🛠️ Troubleshooting

### ALB returns 503
> Health checks haven't passed yet. Wait 2-3 minutes.

```powershell
# SSH into EC2 to check
$ip = terraform -chdir=terraform output -raw ec2_public_ip
ssh -i terraform/k8s-ec2-key ec2-user@$ip

# On EC2:
kubectl get pods          # all pods Running?
kubectl get svc           # NodePort 30080 mapped?
curl http://localhost:30080  # app responding?
```

### Provisioner SSH timeout
> EC2 user_data (Docker + kind pull) takes ~5 min. If it times out, re-run:
```powershell
terraform -chdir=terraform apply -auto-approve
```

### Check user_data logs on EC2
```bash
sudo cat /var/log/user-data.log
```

---

## ✅ Acceptance Criteria

| Criteria | Status |
|---|---|
| 1 command → app running at ALB URL | ✅ `terraform apply -auto-approve` |
| App runs in K8s (not directly on EC2) | ✅ `kubernetes_deployment` with 2 pods |
| ≥ 2 Terraform providers wired | ✅ AWS + Kubernetes + Null (3 providers) |
| Reproducible from clean repo | ✅ Only needs `ssh-keygen` one-time + `terraform apply` |
| Destroys cleanly | ✅ `terraform destroy -auto-approve` |

---

## 👤 Author

**Le Van Hai** — Xbrain × AWS Accelerator Program, Week 8

##############################################################
# main.tf — K8s on AWS: 1-Click Terraform
#
# Providers wired:
#   1. hashicorp/aws        — EC2, SG, ALB, Key Pair, VPC
#   2. hashicorp/kubernetes — K8s Deployment + Service (kind cluster on EC2)
#   3. hashicorp/null       — Provisioner bridge (build image, export kubeconfig)
#
# Flow:
#   terraform apply
#     → EC2 created + user_data installs Docker/kind/kubectl, starts cluster
#     → null_resource: SSH in, copy app, build Docker image, load into kind,
#                      export kubeconfig with EC2 public IP to local file
#     → kubernetes provider reads local kubeconfig file
#     → kubernetes_deployment + kubernetes_service created in the cluster
#     → ALB → EC2:30080 → K8s NodePort → nginx pod serving the app
##############################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Provider 1: AWS — infrastructure layer
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Provider 2: Kubernetes — wired to the kind cluster running on EC2
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    # Provider 3: Null — provisioner bridge between AWS and Kubernetes
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ===========================================================================
# PROVIDER: AWS
# ===========================================================================
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ===========================================================================
# PROVIDER: Kubernetes
# Wired to the kind cluster on EC2.
# kubeconfig is a placeholder until null_resource.k8s_setup overwrites it
# with the real kubeconfig (server URL = EC2 public IP).
# kubernetes_* resources depend on null_resource.k8s_setup, guaranteeing
# the real kubeconfig is in place before any K8s API calls are made.
# ===========================================================================
provider "kubernetes" {
  config_path = "${path.module}/kubeconfig"
  # kind cluster TLS cert does not include the EC2 public IP as a SAN.
  # insecure=true skips TLS verification — acceptable for a dev/demo cluster.
  insecure    = true
}

# ===========================================================================
# LOCALS
# ===========================================================================
locals {
  common_tags = {
    Project     = var.project_name
    Environment = "dev"
    ManagedBy   = "Terraform"
    Owner       = "LeVanHai"
  }
}

# ===========================================================================
# DATA SOURCES
# ===========================================================================

# Latest Amazon Linux 2023 AMI (x86_64)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Default VPC
data "aws_vpc" "default" {
  default = true
}

# Public subnets in the default VPC (at least 2 required for ALB)
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# ===========================================================================
# KEY PAIR — Uses pre-generated SSH key (k8s-ec2-key / k8s-ec2-key.pub)
# ===========================================================================
resource "aws_key_pair" "k8s_key" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.ssh_public_key_path)

  tags = { Name = "${var.project_name}-key" }
}

# ===========================================================================
# SECURITY GROUPS
# ===========================================================================

# ALB SG: accepts HTTP from Internet, forwards to EC2
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound from Internet to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# EC2 SG: accepts SSH (provisioners), NodePort (from ALB), K8s API (from Terraform)
resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "EC2 running kind K8s cluster"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH for Terraform provisioners"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "K8s NodePort 30080 from ALB only"
    from_port       = 30080
    to_port         = 30080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "K8s API Server 6443 for Terraform Kubernetes provider"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound - Docker pulls, kind images, etc."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}

# ===========================================================================
# EC2 INSTANCE — Runs the kind cluster
# ===========================================================================
resource "aws_instance" "k8s_node" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.k8s_key.key_name
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 30  # GB — AMI requires >= 30GB; extra space for Docker images + kind
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Bootstraps Docker, kind, kubectl and starts the K8s cluster
  user_data = file("${path.module}/userdata.sh")

  tags = { Name = "${var.project_name}-k8s-node" }
}

# ===========================================================================
# NULL RESOURCE — Cluster Setup & Kubeconfig Bridge
#
# This resource bridges the AWS provider and Kubernetes provider:
#   1. Waits for EC2 user_data to finish (kind cluster ready)
#   2. Copies app source files to EC2 via SCP (file provisioner)
#   3. Builds Docker image on EC2, loads it into kind
#   4. Exports kubeconfig with EC2 public IP (replaces 0.0.0.0)
#   5. Downloads kubeconfig to local ./kubeconfig file
#      → Kubernetes provider then uses this file to connect
# ===========================================================================
resource "null_resource" "k8s_setup" {
  depends_on = [aws_instance.k8s_node]

  # Re-run if the EC2 instance is replaced
  triggers = {
    instance_id = aws_instance.k8s_node.id
  }

  # SSH connection for all provisioners below
  connection {
    type        = "ssh"
    host        = aws_instance.k8s_node.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
    timeout     = "15m"
  }

  # Step A: Pre-create the app directory on EC2
  provisioner "remote-exec" {
    inline = ["mkdir -p /home/ec2-user/app"]
  }

  # Step B: Copy local app/ directory (Dockerfile + HTML/CSS/images) to EC2
  provisioner "file" {
    source      = "${path.module}/../app/"
    destination = "/home/ec2-user/app"
  }

  # Step C: Wait for bootstrap, build Docker image, load into kind, export kubeconfig
  provisioner "remote-exec" {
    inline = [
      "echo '>>> [1/4] Waiting for kind cluster bootstrap to complete...'",
      "timeout 720 bash -c 'until [ -f /home/ec2-user/.setup_done ]; do echo \"  still waiting... $(date)\"; sleep 20; done'",
      "echo '>>> [2/4] Building Docker image from app/...'",
      "cd /home/ec2-user/app && docker build -t xbrain-app:latest .",
      "echo '>>> [3/4] Loading image into kind cluster (no registry needed)...'",
      "kind load docker-image xbrain-app:latest --name xbrain-cluster",
      "echo '>>> [4/4] Exporting kubeconfig with public IP ${aws_instance.k8s_node.public_ip}...'",
      "kind get kubeconfig --name xbrain-cluster | sed 's|https://0\\.0\\.0\\.0:6443|https://${aws_instance.k8s_node.public_ip}:6443|g' | sed 's|certificate-authority-data:.*|insecure-skip-tls-verify: true|g' > /home/ec2-user/kubeconfig-public.yaml",
      "chmod 600 /home/ec2-user/kubeconfig-public.yaml",
      "echo '>>> All remote setup steps complete!'",
    ]
  }

  # Step D: Download kubeconfig to local machine so Kubernetes provider can use it
  # Using PowerShell interpreter + single-quoted paths to avoid Windows SCP quoting issues.
  # Remote SCP path must NOT be double-quoted (Windows SCP rejects "user@host:/path" with quotes).
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "scp -i '${path.module}\\k8s-ec2-key' -o StrictHostKeyChecking=no -o UserKnownHostsFile=nul ec2-user@${aws_instance.k8s_node.public_ip}:/home/ec2-user/kubeconfig-public.yaml '${path.module}\\kubeconfig'"
  }
}

# ===========================================================================
# KUBERNETES RESOURCES — Created via Kubernetes provider
# Both depend on null_resource.k8s_setup (kubeconfig must exist first)
# ===========================================================================

# Deployment: 2 replicas of nginx serving the Xbrain app
resource "kubernetes_deployment" "xbrain_app" {
  depends_on = [null_resource.k8s_setup]

  metadata {
    name      = "xbrain-app"
    namespace = "default"
    labels = {
      app        = "xbrain-app"
      version    = "1.0.0"
      managed-by = "terraform"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "xbrain-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "xbrain-app"
        }
      }

      spec {
        container {
          name  = "xbrain-nginx"
          image = "xbrain-app:latest"
          # Never pull — image is loaded into kind via `kind load docker-image`
          image_pull_policy = "Never"

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

# Service: NodePort 30080 → pod port 80
# ALB Target Group points to EC2:30080
resource "kubernetes_service" "xbrain_app" {
  depends_on = [null_resource.k8s_setup]

  metadata {
    name      = "xbrain-app-svc"
    namespace = "default"
    labels = {
      app        = "xbrain-app"
      managed-by = "terraform"
    }
  }

  spec {
    selector = {
      app = "xbrain-app"
    }

    type = "NodePort"

    port {
      name        = "http"
      port        = 80
      target_port = 80
      node_port   = 30080
    }
  }
}

# ===========================================================================
# APPLICATION LOAD BALANCER
# Internet → ALB:80 → Target Group → EC2:30080 → K8s NodePort → Pod:80
# ===========================================================================

resource "aws_lb" "app" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.public.ids

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
  port     = 30080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Register EC2 instance in the target group on NodePort 30080
resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.k8s_node.id
  port             = 30080
}

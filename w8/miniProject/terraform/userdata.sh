#!/bin/bash
# =============================================================================
# userdata.sh — EC2 Bootstrap Script for K8s (kind) on AWS
# Runs as root on first boot. Sets up Docker + kind + kubectl.
# The kind cluster is started here so Terraform provisioners can use it.
# =============================================================================
set -e
exec > /var/log/user-data.log 2>&1
echo "=========================================="
echo "  K8s Bootstrap Started: $(date)"
echo "=========================================="

# ---------------------------------------------------------------------------
# 1. System update & install Docker
# ---------------------------------------------------------------------------
echo "[1/6] Installing Docker..."
dnf update -y
dnf install -y docker git

systemctl enable docker
systemctl start docker

# Wait until Docker daemon is ready
for i in $(seq 1 12); do
  docker info > /dev/null 2>&1 && break
  echo "  Waiting for Docker... attempt $i"
  sleep 5
done

# Add ec2-user to docker group (takes effect on next login/SSH session)
usermod -aG docker ec2-user
echo "  Docker ready."

# ---------------------------------------------------------------------------
# 2. Install kind
# ---------------------------------------------------------------------------
echo "[2/6] Installing kind..."
KIND_VERSION="v0.23.0"
curl -fsSL -o /usr/local/bin/kind \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
chmod +x /usr/local/bin/kind
kind version
echo "  kind installed."

# ---------------------------------------------------------------------------
# 3. Install kubectl
# ---------------------------------------------------------------------------
echo "[3/6] Installing kubectl..."
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSL -o /tmp/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client
echo "  kubectl installed."

# ---------------------------------------------------------------------------
# 4. Create kind cluster config
#    - API server listens on 0.0.0.0:6443 (for Terraform Kubernetes provider)
#    - NodePort 30080 mapped to host:30080 (for ALB Target Group)
# ---------------------------------------------------------------------------
echo "[4/6] Creating kind cluster config..."
cat > /tmp/kind-config.yaml << 'KIND_EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: xbrain-cluster
networking:
  apiServerAddress: "0.0.0.0"
  apiServerPort: 6443
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        listenAddress: "0.0.0.0"
        protocol: TCP
KIND_EOF
echo "  Kind config written."

# ---------------------------------------------------------------------------
# 5. Create the kind cluster (runs as root since Docker is available to root)
# ---------------------------------------------------------------------------
echo "[5/6] Creating kind cluster 'xbrain-cluster' (this may take 2-3 min)..."
kind create cluster --name xbrain-cluster --config /tmp/kind-config.yaml --wait 5m
echo "  kind cluster created."

# ---------------------------------------------------------------------------
# 6. Set up kubeconfig for ec2-user
# ---------------------------------------------------------------------------
echo "[6/6] Setting up kubeconfig for ec2-user..."
mkdir -p /home/ec2-user/.kube
kind get kubeconfig --name xbrain-cluster > /home/ec2-user/.kube/config
chown -R ec2-user:ec2-user /home/ec2-user/.kube
chmod 600 /home/ec2-user/.kube/config

# Verify cluster is accessible
export KUBECONFIG=/home/ec2-user/.kube/config
kubectl cluster-info
kubectl get nodes

echo ""
echo "=========================================="
echo "  Bootstrap Complete: $(date)"
echo "=========================================="

# Signal to Terraform provisioners that setup is done
touch /home/ec2-user/.setup_done
chown ec2-user:ec2-user /home/ec2-user/.setup_done

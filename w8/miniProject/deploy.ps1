#!/usr/bin/env pwsh
# =============================================================================
# deploy.ps1 — 1-Click Deploy Script for K8s on AWS
#
# Usage:
#   .\deploy.ps1           # Deploy
#   .\deploy.ps1 destroy   # Destroy all resources
#
# Why 2x terraform apply?
#   Pass 1: Creates EC2 + ALB + downloads real kubeconfig from kind cluster
#   Pass 2: Kubernetes provider reads real kubeconfig → deploys K8s resources
#   This is the standard pattern when bootstrapping K8s with Terraform in the
#   same apply (provider is initialized before null_resource runs).
# =============================================================================

$ErrorActionPreference = "Stop"
$TF = "terraform"
$TF_DIR = "terraform"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

# ── DESTROY mode ──────────────────────────────────────────────────────────────
if ($args[0] -eq "destroy") {
    Write-Step "DESTROYING all resources..."
    & $TF -chdir=$TF_DIR destroy -auto-approve
    Write-Host ""
    Write-Host "✅ All resources destroyed. No charges will accrue." -ForegroundColor Green
    exit 0
}

# ── DEPLOY mode ───────────────────────────────────────────────────────────────
Write-Step "[0/3] Initializing Terraform providers..."
& $TF -chdir=$TF_DIR init
if ($LASTEXITCODE -ne 0) { Write-Error "terraform init failed"; exit 1 }

Write-Step "[1/3] Pass 1 — Creating AWS infrastructure + K8s cluster setup..."
Write-Host "  → EC2, ALB, Security Groups, Key Pair" -ForegroundColor Yellow
Write-Host "  → SSH into EC2, build Docker image, load into kind cluster" -ForegroundColor Yellow
Write-Host "  → Download kubeconfig to local machine" -ForegroundColor Yellow
& $TF -chdir=$TF_DIR apply -auto-approve
# Pass 1 may exit with code 1 if kubernetes resources fail (expected)
# We continue to Pass 2 regardless

Write-Step "[2/3] Pass 2 — Deploying K8s resources (Deployment + Service)..."
Write-Host "  → Kubernetes provider now reads real kubeconfig" -ForegroundColor Yellow
Write-Host "  → Creating kubernetes_deployment (2 replicas) + kubernetes_service (NodePort)" -ForegroundColor Yellow
& $TF -chdir=$TF_DIR apply -auto-approve
if ($LASTEXITCODE -ne 0) { Write-Error "terraform apply (pass 2) failed"; exit 1 }

Write-Step "[3/3] Done! Getting outputs..."
$ALB_URL = & $TF -chdir=$TF_DIR output -raw alb_url
$EC2_IP  = & $TF -chdir=$TF_DIR output -raw ec2_public_ip

Write-Host ""
Write-Host "🚀 DEPLOYMENT COMPLETE!" -ForegroundColor Green
Write-Host ""
Write-Host "  ALB URL  : $ALB_URL" -ForegroundColor Green
Write-Host "  EC2 IP   : $EC2_IP" -ForegroundColor Green
Write-Host ""
Write-Host "  ⏳ Wait ~2-3 minutes for ALB health checks to pass, then open:" -ForegroundColor Yellow
Write-Host "     $ALB_URL" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To destroy: .\deploy.ps1 destroy" -ForegroundColor Gray

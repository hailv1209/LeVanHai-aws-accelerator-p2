# Self-study D1 — GitOps & CI/CD

> **Chủ đề:** GitHub Actions plan-on-PR + apply-on-merge | ArgoCD vs Flux | app-of-apps | sync waves | rollback

---

## 1. GitOps là gì?

**GitOps** là phương pháp quản lý hạ tầng và ứng dụng bằng **Git** như nguồn chân lý duy nhất (single source of truth). Thay vì thao tác trực tiếp trên cluster (kubectl apply, helm install...), ta push code (manifest) lên Git repo, rồi một **GitOps operator** (ArgoCD / Flux) sẽ tự động sync những thay đổi đó xuống Kubernetes cluster.

**Ưu điểm:**

- **Audit trail** đầy đủ — mọi thay đổi đều qua commit history
- **Rollback dễ dàng** — chỉ cần `git revert` hoặc `git checkout`
- **Tự động hóa hoàn toàn** — không cần manual kubectl
- **Multi-environment** — mỗi branch/folder tương ứng một môi trường

---

## 2. GitHub Actions: Plan-on-PR + Apply-on-Merge

Đây là mô hình 2 bước phổ biến trong GitOps pipeline.

### 2.1 Plan-on-PR (Dry-run / Preview)

Khi một PR được tạo hoặc cập nhật, CI workflow sẽ:

- Chạy `terraform plan` (infrastructure) hoặc `kubectl diff` / `helm template` (app)
- Comment kết quả lên PR (Terraform Plan output, YAML diff...)
- **Không apply gì cả** — chỉ để review

```yaml
# .github/workflows/plan-on-pr.yml
name: Plan on PR

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          # Cần fetch đủ để so sánh với base branch
          fetch-depth: 0

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan
        id: plan
        run: |
          terraform plan -no-color -out=tfplan
          terraform show -no-color tfplan > tfplan.txt

      - name: Post Plan as PR Comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('tfplan.txt', 'utf8');
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '## Terraform Plan\n```\n' + plan + '\n```'
            });
```

### 2.2 Apply-on-Merge (Sau khi merge)

Khi PR được merge vào branch chính (thường là `main`/`master`):

- Chạy `terraform apply` hoặc `kubectl apply`
- Gửi thông báo kết quả (Slack, email...)

```yaml
# .github/workflows/apply-on-merge.yml
name: Apply on Merge

on:
  push:
    branches:
      - main

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: production   # Yêu cầu approve nếu cần
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init

      - name: Terraform Apply
        run: terraform apply -auto-approve
        env:
          TF_VAR_github_token: ${{ secrets.GITHUB_TOKEN }}
```

### 2.3 Kết hợp Plan + Apply (Best Practice)

```yaml
# .github/workflows/gitops.yml
name: GitOps Pipeline

on:
  push:
    branches: [main]
  pull_request:

jobs:
  # Bước 1: Luôn chạy validate
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate YAML manifests
        run: |
          for f in $(find . -name "*.yaml"); do
            kubectl create --dry-run=client -f "$f" || exit 1
          done

  # Bước 2: Plan khi có PR
  plan:
    needs: validate
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Terraform Plan
        run: terraform plan -no-color | tee plan.txt
      - name: Comment PR
        run: |
          github粗糙 rest.issues.createComment({...})

  # Bước 3: Apply khi merge vào main
  apply:
    needs: validate
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Terraform Apply
        run: terraform apply -auto-approve
```

---

## 3. ArgoCD vs Flux

Cả hai đều là GitOps operators cho Kubernetes, nhưng khác nhau về kiến trúc và use case.

### So sánh chi tiết

| Tiêu chí | ArgoCD | Flux |
|---|---|---|
| **Ngôn ngữ** | Go | Go |
| **Giao diện** | Web UI + CLI | CLI chủ yếu |
| **CRD** | ArgoCD App, Application, ApplicationSet | Flux Kustomization, GitRepository, HelmRelease |
| **Multi-cluster** | Tích hợp sẵn (ArgoCD Server + many clusters) | Fleet manager (Fleet) |
| **YAML manifest** | Dùng ArgoCD Application manifest | Dùng Kustomization CRD |
| **Drift detection** | Tự động, có dashboard | Tự động, CLI |
| **Helm support** | Có | Có (HelmRelease CRD) |
| **Kustomize** | Có | Có (built-in) |
| **Image updater** | ArgoCD Image Updater (plugin) | Flux CD Image Updater (built-in) |
| **RBAC** | Tích hợp sẵn | Via OPA/Gatekeeper |
| **Community** | Akuity (commercial) + CNCF | CNCF, Weaveworks origin |
| **Độ phức tạp** | Trung bình, nhiều tính năng | Thấp, modular |

### 3.1 ArgoCD

```yaml
# Install ArgoCD (manifest)
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
# Application manifest
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/k8s-manifests.git
    targetRevision: HEAD
    path: ./apps/my-app/base
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true        # Xóa resource không còn trong Git
      selfHeal: true     # Tự động sync khi có drift
    syncOptions:
      - CreateNamespace=true
```

**Ưu điểm ArgoCD:**

- Dashboard trực quan, dễ track sync status
- ApplicationSet hỗ trợ multi-cluster / multi-environment
- RBAC mạnh mẽ
- Animation sync đẹp mắt

**Nhược điểm:**

- Giao diện Web có thể phức tạp với người mới
- Nhiều CRD hơn, resource nặng hơn

### 3.2 Flux

```yaml
# 1. GitRepository — khai báo nguồn Git
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/myorg/k8s-manifests.git
  ref:
    branch: main

---
# 2. Kustomization — sync manifest xuống cluster
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 1m
  path: ./apps/my-app
  prune: true
  sourceRef:
    kind: GitRepository
    name: my-app
  targetNamespace: my-app
```

**Ưu điểm Flux:**

- Modular — chỉ cài what you need
- Nhẹ hơn, dễ integrate vào CI/CD
- Image Updater mạnh mẽ (auto-update tag khi image thay đổi)
- Tích hợp tốt với Weave GitOps (UI)

**Nhược điểm:**

- CLI-only mặc định, cần thêm tool để có UI
- Multi-cluster phức tạp hơn ArgoCD

### 3.3 Khi nào chọn cái nào?

```
ArgoCD  → Cần dashboard trực quan, multi-cluster, team cần visibility cao
Flux    → Team ops-oriented, muốn nhẹ, tích hợp CI-native
```

---

## 4. App-of-Apps Pattern

App-of-Apps là pattern trong đó một **App (parent)** có nhiệm vụ deploy nhiều **Apps (children)** khác. Thay vì khai báo từng ứng dụng riêng lẻ, ta dùng một "bootstrap app" để quản lý toàn bộ.

### 4.1 Tại sao cần?

- **Quản lý tập trung** — tất cả app được khai báo ở một chỗ
- **DRY** — không lặp lại cấu hình cho từng app
- **Bootstrap cluster** — deploy app-of-apps ngay khi cluster khởi tạo
- **Environment tiers** — dev, staging, prod đều được quản lý qua cùng một repo

### 4.2 ArgoCD App-of-Apps

```yaml
# 1. Bootstrap App (root app) — deploy toàn bộ hệ thống
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/gitops.git
    path: clusters/prod/root-app
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```yaml
# 2. apps/ Chart (Helm hoặc Kustomize)
# clusters/prod/root-app/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: frontend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/gitops.git
    path: apps/frontend
  destination:
    server: https://kubernetes.default.svc
    namespace: frontend

---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backend-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/gitops.git
    path: apps/backend-api
  destination:
    server: https://kubernetes.default.svc
    namespace: backend-api

---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: database
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/gitops.git
    path: apps/database
  destination:
    server: https://kubernetes.default.svc
    namespace: database
```

### 4.3 Flux App-of-Apps (Kustomization chain)

```yaml
# 1. Root Kustomization
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/prod/apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
---
# 2. apps/kustomization.yaml — tham chiếu từng app
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: frontend
  namespace: flux-system
spec:
  interval: 5m
  path: ./apps/frontend
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: backend-api
  namespace: flux-system
spec:
  interval: 5m
  path: ./apps/backend-api
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

---

## 5. Sync Waves

Sync Waves là cơ chế **thứ tự deploy** của ArgoCD / Flux — các resource được sắp xếp theo "wave" (đợt sóng), đảm bảo dependency được apply trước khi resource phụ thuộc vào được deploy.

### 5.1 ArgoCD — Wave Annotation

```yaml
# 1. Namespace (wave 0 — chạy trước)
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
# 2. RBAC / ServiceAccount (wave 1)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
# 3. ConfigMap / Secret (wave 2)
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
  namespace: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "2"
data:
  DATABASE_URL: "postgres://db:5432/app"
---
# 4. Deployment (wave 3 — chạy cuối)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  replicas: 3
  template:
    spec:
      serviceAccountName: my-app-sa
```

**Thứ tự thực thi:**

```
Wave 0 → Namespace
Wave 1 → ServiceAccount + RBAC
Wave 2 → ConfigMap + Secret
Wave 3 → Deployment + Service
```

### 5.2 Flux — Depends-On (Kustomize)

Flux dùng annotation `kustomize.toolkit.fluxcd.io/depends-on`:

```yaml
# Deployment phụ thuộc vào ConfigMap
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  replicas: 3
---
# Annotation để Flux hiểu dependency
# Flux sẽ tự động apply theo thứ tự dependency graph
```

### 5.3 Tại sao cần Sync Waves?

```
Ví dụ: Deployment cần:
  1. Namespace tồn tại → wave 0
  2. ServiceAccount có quyền → wave 1
  3. Secret/ConfigMap chứa credentials → wave 2
  4. Deployment mới mount được secret → wave 3

Không có wave: Deployment apply trước → lỗi vì thiếu dependency
Có wave:    Đúng thứ tự → tất cả resource sẵn sàng trước khi pod chạy
```

---

## 6. Rollback — Git Revert vs kubectl rollout undo

Có hai chiến lược rollback phổ biến trong GitOps:

### 6.1 kubectl rollout undo

Rollback về phiên bản trước đó mà **không thay đổi Git**.

```bash
# Rollback Deployment về revision trước
kubectl rollout undo deployment/my-app -n my-app

# Rollback về revision cụ thể
kubectl rollout undo deployment/my-app -n my-app --to-revision=3

# Kiểm tra lịch sử revision
kubectl rollout history deployment/my-app -n my-app

# Theo dõi trạng thái rollback
kubectl rollout status deployment/my-app -n my-app
```

**Đặc điểm:**

- **Tác động:** Chỉ thay đổi trên cluster, Git repo giữ nguyên (vẫn trỏ đến version mới)
- **Nhanh:** Không cần commit/push
- **Nguy hiểm:** Git và cluster **drift** (không đồng bộ) → ArgoCD/Flux sẽ tự động sync lại version mới từ Git
- **Phù hợp:** Rollback tạm thời / khẩn cấp

### 6.2 Git Revert

Rollback bằng cách tạo **commit mới** đảo ngược thay đổi.

```bash
# Tạo commit revert thay đổi ở commit cụ thể
git revert <commit-hash>

# Revert merge commit (cần -m để chỉ parent)
git revert -m 1 <merge-commit-hash>

# Push lên remote → ArgoCD/Flux tự detect và sync
git push origin main
```

```bash
# Ví dụ: muốn revert về trạng thái trước commit abc123
git log --oneline
# abc123 (HEAD) Fix: update deployment image to v2.1
# def456 Improve: scale replicas to 5
# 789abc Init: first deployment

git revert abc123 --no-edit
# Tạo commit mới: "Revert 'Fix: update deployment image to v2.1'"

git push origin main
# ArgoCD/Flux detect change → sync cluster về state mới (trước abc123)
```

**Đặc điểm:**

- **Tác động:** Git và cluster luôn đồng bộ
- **An toàn:** Phù hợp với GitOps — không bao giờ có drift
- **Chậm hơn:** Cần commit + push + ArgoCD/Flux sync (vài phút)
- **Audit trail:** Giữ nguyên lịch sử (không xóa commit cũ)
- **Phù hợp:** Rollback chính thức, release management

### 6.3 So sánh trực tiếp

| Tiêu chí | `kubectl rollout undo` | `git revert` |
|---|---|---|
| **Thay đổi Git** | Không | Có (tạo revert commit) |
| **Drift risk** | Cao — cluster khác Git | Không — Git là nguồn chân lý |
| **Tốc độ** | Tức thì | Vài phút (commit + sync) |
| **Audit trail** | Không lưu trong Git | Lưu trong Git history |
| **Auto-sync GitOps** | ArgoCD sẽ overwrite | ArgoCD sẽ apply |
| **Use case tốt** | Khẩn cấp, hotfix tạm | Rollback chính thức |

### 6.4 Best Practice trong GitOps

```bash
# ✅ ĐÚNG: Dùng git revert (hoặc git checkout) để rollback
git checkout <tag-v1.0> -- ./k8s/  # Lấy manifest version cũ
git commit -m "Rollback to v1.0"
git push origin main
# ArgoCD/Flux tự động sync cluster về v1.0

# ❌ SAI: kubectl rollout undo trong môi trường GitOps
kubectl rollout undo deployment/my-app
# ArgoCD sẽ detect drift → tự sync lại version mới từ Git
# → Rollback không hiệu quả!
```

> **Quy tắc vàng:** Trong GitOps, **luôn rollback bằng Git**. `kubectl rollout undo` chỉ dùng khi cluster hoàn toàn tách biệt (không dùng GitOps).

---

## Tổng kết

| Chủ đề | Key take-away |
|---|---|
| **GitOps** | Git = source of truth; Operator (ArgoCD/Flux) sync xuống cluster |
| **Plan-on-PR** | PR → CI chạy plan/diff → comment lên PR → không apply |
| **Apply-on-Merge** | Merge → CI chạy apply → infra/manifest được deploy |
| **ArgoCD** | UI đẹp, multi-cluster mạnh, ApplicationSet |
| **Flux** | Modular, nhẹ, Image Updater built-in |
| **App-of-Apps** | Một app quản lý nhiều app con — DRY, bootstrap dễ |
| **Sync Waves** | Dùng annotation để control thứ tự apply resource |
| **Rollback** | Ưu tiên `git revert` trong GitOps; `kubectl rollout undo` chỉ dùng trong emergency |

---
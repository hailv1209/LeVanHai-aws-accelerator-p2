# Day-2 Labs — Secrets Rotation + Supply Chain Security

**Namespace dùng chung cho K8s labs:** `supply-chain-lab`
**Tạo namespace trước:**
```bash
kubectl create ns supply-chain-lab
```

---

## Lab 1 — AWS Secrets Manager: Tạo Secret + IAM Role

**Mục tiêu:** Tạo một secret trong AWS Secrets Manager, cấu hình IAM policy cho phép đọc secret.

**Điều kiện tiên quyết:** AWS CLI đã cấu hình (`aws configure`), có AWS account với quyền tạo Secrets Manager + IAM.

### Các bước thực hiện

**Step 1 — Tạo Secret trong AWS Secrets Manager**
```bash
aws secretsmanager create-secret \
  --name supply-chain/db-password \
  --description "DB password for supply chain demo" \
  --secret-string '{"username":"admin","password":"MySecretPass2024!"}'
```

**Step 2 — Verify secret đã tạo**
```bash
aws secretsmanager get-secret-value --secret-id supply-chain/db-password
# Mong đợi: JSON output chứa username + password
```

**Step 3 — Tạo IAM Policy cho ESO**
```bash
cat <<EOF > iam-policy-eso.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:supply-chain/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ESOSecretsManagerAccess \
  --policy-document file://iam-policy-eso.json
```

**Step 4 — Ghi lại ARN của policy**
```bash
aws iam list-policies --scope Local --query 'Policies[?PolicyName==`ESOSecretsManagerAccess`].Arn' --output text
# Lưu ARN này để dùng trong Step 5 (Trust Policy)
```

**Step 5 — Tạo IAM Role với Trust Policy cho IRSA**
```bash
cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:external-secrets:external-secrets-sa"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name ESO-SecretsManager-Role \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name ESO-SecretsManager-Role \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/ESOSecretsManagerAccess
```

> **Lưu ý:** Thay `<ACCOUNT_ID>`, `<REGION>`, `<OIDC_ID>` bằng giá trị thực tế của cluster EKS của bạn. Nếu dùng kind/minikube, bỏ qua Lab 5 (IRSA) — dùng credentials-based SecretStore thay thế.

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| `aws secretsmanager get-secret-value` | Trả về JSON với `username` + `password` |
| `aws iam list-policies \| grep ESO` | Hiển thị policy `ESOSecretsManagerAccess` |
| `aws iam get-role --role-name ESO-SecretsManager-Role` | Hiển thị role + trust policy |

---

## Lab 2 — Install ESO + ClusterSecretStore + ExternalSecret sync

**Mục tiêu:** Install External Secrets Operator vào cluster, cấu hình ClusterSecretStore kết nối AWS Secrets Manager, và tạo ExternalSecret để sync secret vào K8s.

**Điều kiện tiên quyết:** K8s cluster đang chạy, Helm installed.

### Các bước thực hiện

**Step 1 — Install ESO qua Helm**
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace
```

**Step 2 — Verify ESO pod đang chạy**
```bash
kubectl get pods -n external-secrets
# Mong đợi: các pod external-secrets-* đang Running
```

**Step 3 — Tạo ServiceAccount với IRSA annotation (EKS only)**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  namespace: external-secrets
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/ESO-SecretsManager-Role
EOF
```

> **Nếu dùng kind/minikube (không có IRSA):** Bỏ qua Step 3, dùng credentials-based approach trong Step 4.

**Step 4 — Tạo ClusterSecretStore**

*EKS (IRSA):*
```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-backend
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-southeast-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
EOF
```

*kind/minikube (credentials-based):*
```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-backend
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-southeast-1
      auth:
        static:
          accessKeyID: "<AWS_ACCESS_KEY_ID>"
          secretAccessKeySecretRef:
            name: aws-credentials
            key: secret-access-key
EOF

# Tạo secret chứa AWS credentials
kubectl create secret generic aws-credentials \
  --from-literal=secret-access-key="<AWS_SECRET_ACCESS_KEY>" \
  -n external-secrets
```

**Step 5 — Tạo ExternalSecret**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: supply-chain-lab
spec:
  refreshInterval: "10s"           # Re-sync mỗi 10s (lab), production: "1h"
  secretStoreRef:
    name: aws-backend
    kind: ClusterSecretStore
  target:
    name: db-credentials            # Tên K8s Secret output
    creationPolicy: Owner
  data:
    - secretKey: username           # Key trong K8s Secret output
      remoteRef:
        key: supply-chain/db-password
        property: username
    - secretKey: password
      remoteRef:
        key: supply-chain/db-password
        property: password
EOF
```

**Step 6 — Verify ExternalSecret đã sync**
```bash
kubectl get externalsecret -n supply-chain-lab
# Mong đợi: STATUS = Ready

kubectl describe externalsecret db-credentials -n supply-chain-lab
# Xem events: "Secret synced successfully"
```

**Step 7 — Verify K8s Secret được tạo**
```bash
kubectl get secret db-credentials -n supply-chain-lab

# Đọc giá trị
kubectl get secret db-credentials -n supply-chain-lab \
  -o jsonpath='{.data.username}' | base64 -d
kubectl get secret db-credentials -n supply-chain-lab \
  -o jsonpath='{.data.password}' | base64 -d
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| ESO pods | Running trong `external-secrets` ns |
| ClusterSecretStore | Đã tạo, status Ready |
| ExternalSecret | Status = Ready, không có errors |
| K8s Secret `db-credentials` | Tồn tại trong `supply-chain-lab`, có data đúng |
| `kubectl get secret ... \| base64 -d` | Hiển thị `admin` và `MySecretPass2024!` |

---

## Lab 3 — Test: Rotation + refreshInterval

**Mục tiêu:** Test ESO tự động re-sync secret sau khi giá trị trong AWS Secrets Manager thay đổi, nhờ `refreshInterval`.

**Điều kiện tiên quyết:** Hoàn thành Lab 2.

### Các bước thực hiện

**Step 1 — Đọc giá trị secret hiện tại từ K8s**
```bash
kubectl get secret db-credentials -n supply-chain-lab \
  -o jsonpath='{.data.password}' | base64 -d
# Lưu giá trị này để so sánh sau
```

**Step 2 — Thay đổi secret trong AWS Secrets Manager**
```bash
aws secretsmanager update-secret \
  --secret-id supply-chain/db-password \
  --secret-string '{"username":"admin","password":"NewSecretPass2025!"}'
```

**Step 3 — Đợi refreshInterval (10s) + verify**
```bash
# Đợi 15 giây (đảm bảo > refreshInterval)
sleep 15

# Đọc lại từ K8s
kubectl get secret db-credentials -n supply-chain-lab \
  -o jsonpath='{.data.password}' | base64 -d
# Mong đợi: NewSecretPass2025! (đã cập nhật)
```

**Step 4 — Xem ExternalSecret events**
```bash
kubectl describe externalsecret db-credentials -n supply-chain-lab | grep -A5 Events
# Mong đợi: event "Secret synced successfully" xuất hiện sau khi update
```

**Step 5 — Thử đổi refreshInterval**
```bash
kubectl patch externalsecret db-credentials -n supply-chain-lab \
  --type=merge \
  -p '{"spec":{"refreshInterval":"5s"}}'

# Verify đã đổi
kubectl get externalsecret db-credentials -n supply-chain-lab \
  -o jsonpath='{.spec.refreshInterval}'
# Mong đợi: 5s
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| Password trước khi update | `MySecretPass2024!` |
| Password sau 15s | `NewSecretPass2025!` |
| refreshInterval sau patch | `5s` |
| ExternalSecret events | Có event "Secret synced" sau mỗi update |

---

## Lab 4 — Trivy CLI: Scan local image + fail threshold

**Mục tiêu:** Dùng Trivy để scan một container image local, hiểu severity levels và cách fail build.

**Điều kiện tiên quyết:** Trivy đã installed, Docker đang chạy.

### Các bước thực hiện

**Step 1 — Pull một image có vulnerabilities để test**
```bash
docker pull alpine:3.14
docker pull nginx:1.25
```

**Step 2 — Scan image (default — tất cả severities)**
```bash
trivy image alpine:3.14
# Xem output: danh sách vulnerabilities với severity CRITICAL/HIGH/MEDIUM/LOW
```

**Step 3 — Scan chỉ CRITICAL + HIGH**
```bash
trivy image --severity CRITICAL,HIGH alpine:3.14
# Chỉ hiển thị CRITICAL và HIGH vulnerabilities
```

**Step 4 — Scan với exit-code (fail nếu có vuln)**
```bash
trivy image \
  --severity CRITICAL,HIGH \
  --exit-code 1 \
  alpine:3.14

echo "Exit code: $?"
# Mong đợi: Exit code = 1 (vì alpine:3.14 có HIGH/CRITICAL vulns)
```

**Step 5 — Scan image an toàn (alpine mới)**
```bash
docker pull alpine:3.19
trivy image --severity CRITICAL,HIGH --exit-code 1 alpine:3.19
echo "Exit code: $?"
# Mong đợi: Exit code = 0 (không có CRITICAL/HIGH vulns)
```

**Step 6 — Scan filesystem (Dockerfile + dependencies)**
```bash
# Tạo thư mục test
mkdir -p /tmp/trivy-test && cd /tmp/trivy-test

cat <<EOF > Dockerfile
FROM python:3.9-slim
RUN pip install requests==2.6.0
EOF

trivy fs . --scanners vuln,secret,config
# Xem: vuln trong python:3.9-slim + secret scanning (nếu có) + config issues
```

**Step 7 — Output JSON để CI**
```bash
trivy image --format json --output trivy-results.json alpine:3.14
# File JSON chứa full vulnerability data (để process trong CI)
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| `trivy image alpine:3.14` | Hiển thị danh sách vulns (có CRITICAL/HIGH) |
| `trivy image --severity CRITICAL,HIGH --exit-code 1 alpine:3.14` | Exit code = 1 |
| `trivy image --severity CRITICAL,HIGH --exit-code 1 alpine:3.19` | Exit code = 0 |
| `trivy fs .` | Hiển thị vulns trong Dockerfile dependencies |
| `trivy-results.json` | File JSON tồn tại với vulnerability data |

---

## Lab 5 — Trivy trong GitHub Actions: Scan image trong CI

**Mục tiêu:** Tạo GitHub Actions workflow chạy Trivy scan sau khi build image, upload SARIF vào GitHub Security tab.

**Điều kiện tiên quyết:** Có GitHub repo, Dockerfile trong repo.

### Các bước thực hiện

**Step 1 — Tạo Dockerfile trong repo**
```dockerfile
# Dockerfile (ở root của repo)
FROM nginx:1.25-alpine
LABEL maintainer="your-username"
```

**Step 2 — Tạo `.trivyignore`**
```
# .trivyignore
CVE-2024-xxxx  # Placeholder — ignore CVE-2024-xxxx
```

**Step 3 — Tạo GitHub Actions workflow**
```yaml
# .github/workflows/trivy-scan.yml
name: Trivy Image Scan

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-scan:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Build image
        run: docker build -t myapp:${{ github.sha }} .

      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: 'myapp:${{ github.sha }}'
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'
          exit-code: '1'        # Fail build nếu có CRITICAL/HIGH

      - name: Upload Trivy scan results to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: 'trivy-results.sarif'

      - name: Check for CRITICAL/HIGH vulnerabilities
        run: |
          if [ -f trivy-results.sarif ]; then
            echo "⚠️ Trivy found vulnerabilities — check Security tab"
          else
            echo "✅ No CRITICAL/HIGH vulnerabilities found"
          fi
```

**Step 4 — Commit và push workflow**
```bash
git add .github/workflows/trivy-scan.yml Dockerfile .trivyignore
git commit -m "Add Trivy scan CI workflow"
git push origin main
```

**Step 5 — Xem kết quả trên GitHub**
- Vào repo → **Actions** tab → xem workflow run
- Vào **Security > Code scanning alerts** → xem SARIF results

**Step 6 — Test: đẩy một image có vulnerability**
```bash
# Sửa Dockerfile để dùng image có known vuln
# Ví dụ: FROM python:3.6-slim (có nhiều CVE cũ)
# Commit + push → xem CI fail
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đụi |
|---|---|
| GitHub Actions run | Hoàn thành (success hoặc fail tùy image) |
| Security > Code scanning | Hiển thị vulnerabilities (nếu có) |
| CI fail với `--exit-code 1` | Build fail khi có CRITICAL/HIGH |
| `.trivyignore` | CVE trong file được bỏ qua |

---

## Lab 6 — Cosign Keyless OIDC: Sign image

**Mục tiêu:** Dùng Cosign keyless signing (OIDC) để sign một container image đã push lên registry.

**Điều kiện tiên quyết:** Cosign installed, Docker đang chạy, có registry account (Docker Hub / GHCR / ECR).

### Các bước thực hiện

**Step 1 — Build và push image lên registry**
```bash
# Build image
docker build -t ghcr.io/<your-username>/demo-signed-app:latest .

# Login vào registry (GHCR example)
echo "<GHCR_PAT>" | docker login ghcr.io -u <your-username> --password-stdin

# Push
docker push ghcr.io/<your-username>/demo-signed-app:latest
```

**Step 2 — Cosign login (OIDC flow)**
```bash
# Login vào registry qua OIDC (không cần password)
cosign login ghcr.io
# Mở browser để xác thực OIDC (nếu local)
# Trong CI: không cần login, OIDC token được inject tự động
```

**Step 3 — Keyless sign image**
```bash
cosign sign --yes ghcr.io/<your-username>/demo-signed-app:latest
# --yes = không prompt confirm
# Output: "Pushing signature to ghcr.io/..."
```

> **Lưu ý:** Keyless sign cần OIDC token. Trong CI (GitHub Actions), dùng workflow OIDC:
> ```yaml
> - name: Sign image
>   uses: sigstore/cosign-installer@v3
> - name: Sign with keyless
>   run: cosign sign --yes ${{ steps.meta.outputs.tags }}
>   env:
>     COSIGN_EXPERIMENTAL: "1"
> ```

**Step 4 — Verify signature**
```bash
cosign verify ghcr.io/<your-username>/demo-signed-app:latest
# Mong đợi: "Verified" + certificate subject + issuer
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| `cosign sign` output | "Pushing signature..." thành công |
| `cosign verify <image>` | In `Verified OK` với certificate info |
| Registry | Image có thêm artifact (signature) |

---

## Lab 7 — Cosign Key-based: Generate keypair + sign + verify

**Mục tiêu:** Tạo keypair Cosign, sign image bằng private key, và verify bằng public key.

**Điều kiện tiên quyết:** Cosign installed, Docker đang chạy.

### Các bước thực hiện

**Step 1 — Generate keypair**
```bash
cosign generate-key-pair
# Output:
#   cosign.key (private key) — GIỮ AN TOÀN
#   cosign.pub  (public key)  — có thể chia sẻ

# Lưu private key vào K8s Secret (production) hoặc secure storage
ls -la cosign.key cosign.pub
```

**Step 2 — Sign image với private key**
```bash
cosign sign --key cosign.key --yes ghcr.io/<your-username>/demo-keybased-app:latest
```

**Step 3 — Verify với public key**
```bash
cosign verify --key cosign.pub ghcr.io/<your-username>/demo-keybased-app:latest
# Mong đợi: "Verified OK"
```

**Step 4 — Thử verify với key sai (phải fail)**
```bash
# Tạo keypair khác
cosign generate-key-pair -kf wrong.key

# Verify với wrong public key → phải fail
cosign verify --key wrong.pub ghcr.io/<your-username>/demo-keybased-app:latest
# Mong đợi: "Error: could not verify image" hoặc tương tự
```

**Step 5 — Xem signature details**
```bash
cosign tree ghcr.io/<your-username>/demo-keybased-app:latest
# Hiển thị: image + signature layers

cosign triangulate ghcr.io/<your-username>/demo-keybased-app:latest
# Hiển thị: vị trí signature artifact
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| `cosign.key` + `cosign.pub` | Hai file được tạo |
| `cosign sign --key cosign.key` | "Pushing signature..." thành công |
| `cosign verify --key cosign.pub` | "Verified OK" |
| `cosign verify --key wrong.pub` | **FAIL** — "could not verify" |

---

## Lab 8 — Kyverno: Install + Deny unsigned images

**Mục tiêu:** Install Kyverno, tạo ClusterPolicy `verifyImages` để từ chối mọi image chưa được Cosign sign.

**Điều kiện tiên quyết:** K8s cluster đang chạy, Helm installed.

### Các bước thực hiện

**Step 1 — Install Kyverno**
```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set backgroundController.serviceAccount.create=true \
  --set cleanupController.serviceAccount.create=true \
  --set reportsController.serviceAccount.create=true
```

**Step 2 — Verify Kyverno pods**
```bash
kubectl get pods -n kyverno
# Mong đợi: kyverno-admission-controller, kyverno-background-controller, kyverno-cleanup-controller đều Running
```

**Step 3 — Tạo ClusterPolicy deny unsigned images**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: deny-unsigned-images
spec:
  validationFailureAction: Enforce   # Reject nếu verify fail
  background: true
  rules:
  - name: verify-signed
    match:
      any:
      - resources:
          kinds:
          - Pod
    verifyImages:
    - imageReferences:
      - "*/*"                          # Tất cả images
      attestors:
      - entries:
        - keyless:
            issuer: https://token.actions.githubusercontent.com
            subject: https://github.com/<your-username>/*/.github/workflows/*.yml@refs/heads/main
            rekor:
              url: https://rekor.sigstore.dev
EOF
```

**Step 4 — Test: tạo Pod với image chưa sign → bị từ chối**
```bash
cat <<EOF | kubectl apply -f - --namespace=supply-chain-lab
apiVersion: v1
kind: Pod
metadata:
  name: unsigned-test
  namespace: supply-chain-lab
spec:
  containers:
  - name: nginx
    image: nginx:1.25               # Image chưa sign → bị deny
EOF

# Mong đợi: Error from server — admission webhook denied
```

**Step 5 — Test: Pod với image đã sign → cho phép**
```bash
# Dùng image đã sign trong Lab 6
cat <<EOF | kubectl apply -f - --namespace=supply-chain-lab
apiVersion: v1
kind: Pod
metadata:
  name: signed-test
  namespace: supply-chain-lab
spec:
  containers:
  - name: app
    image: ghcr.io/<your-username>/demo-signed-app:latest  # Đã sign
EOF

# Mong đợi: Pod được tạo thành công
kubectl get pod signed-test -n supply-chain-lab
```

**Step 6 — Xem PolicyReport (audit results)**
```bash
kubectl get policyreport -n supply-chain-lab
# Xem pass/fail reports của Kyverno
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| Kyverno pods | Running trong ns `kyverno` |
| Policy `deny-unsigned-images` | Active, Enforce mode |
| Tạo Pod với `nginx:1.25` | **Bị từ chối** — admission denied |
| Tạo Pod với signed image | **Thành công** |
| PolicyReport | Hiển thị pass/fail records |

---

## Lab 9 — Kyverno + Cosign Keyless: Allow only signed images

**Mục tiêu:** Tích hợp Kyverno `verifyImages` với Cosign keyless signing — chỉ cho phép image được sign bởi CI workflow cụ thể.

**Điều kiện tiên quyết:** Hoàn thành Lab 6 (Cosign sign) + Lab 8 (Kyverno).

### Các bước thực hiện

**Step 1 — Cấu hình verifyImages với certificate identity cụ thể**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: allow-only-ci-signed
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: verify-ci-signature
    match:
      any:
      - resources:
          kinds:
          - Pod
    verifyImages:
    - imageReferences:
      - "ghcr.io/<your-username>/*"     # Chỉ check images từ GHCR của bạn
      attestors:
      - entries:
        - keyless:
            # GitHub Actions OIDC issuer
            issuer: https://token.actions.githubusercontent.com

            # Certificate subject: CI workflow cụ thể
            subject: https://github.com/<your-username>/<repo>/.github/workflows/build-and-sign.yml@refs/heads/main

            rekor:
              url: https://rekor.sigstore.dev
EOF
```

**Step 2 — Test: Deploy image được sign bởi GitHub Actions CI**
```bash
# Image này phải được sign bởi GitHub Actions workflow (Lab 6)
cat <<EOF | kubectl apply -f - --namespace=supply-chain-lab
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ci-signed-app
  namespace: supply-chain-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ci-signed
  template:
    metadata:
      labels:
        app: ci-signed
    spec:
      containers:
      - name: app
        image: ghcr.io/<your-username>/demo-signed-app:latest
        ports:
        - containerPort: 80
EOF

# Mong đợi: Deployment tạo được (vì image đã sign)
kubectl get deployment ci-signed-app -n supply-chain-lab
```

**Step 3 — Test: Image sign locally (không phải CI) → bị deny**
```bash
# Image này được sign locally bằng `cosign sign` (không qua CI OIDC)
# Certificate subject sẽ khác với policy → bị deny

cat <<EOF | kubectl apply -f - --namespace=supply-chain-lab
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-signed-app
  namespace: supply-chain-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-signed
  template:
    metadata:
      labels:
        app: local-signed
    spec:
      containers:
      - name: app
        image: ghcr.io/<your-username>/demo-keybased-app:latest  # Key-based, không qua CI
        ports:
        - containerPort: 80
EOF

# Mong đợi: Bị deny (certificate identity không match)
# Hoặc nếu dùng key-based attestor → có thể cho pass
```

**Step 4 — Chuyển sang Audit mode để xem violations không block**
```bash
kubectl patch clusterpolicy allow-only-ci-signed \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'

# Bây giờ Pod/Deployment vi phạm vẫn tạo được, nhưng được ghi vào PolicyReport
kubectl get policyreport -n supply-chain-lab
```

**Step 5 — Chuyển lại Enforce mode**
```bash
kubectl patch clusterpolicy allow-only-ci-signed \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| Policy `allow-only-ci-signed` | Active, Enforce mode |
| Deploy `ci-signed-app` (image qua CI) | **Thành công** (certificate match) |
| Deploy `local-signed-app` (key-based locally) | **Bị deny** (certificate mismatch) |
| Chuyển Audit → Enforce | Pod vi phạm bị block lại |

---

## Lab 10 — CVE Exception: Wildcard + Certificate exception

**Mục tiêu:** Cấu hình Kyverno policy với CVE exception patterns: wildcard ignore và certificate-based exception cho legacy app.

**Điều kiện tiên quyết:** Hoàn thành Lab 8 (Kyverno).

### Các bước thực hiện

**Step 1 — Tạo policy với wildcard CVE exception**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: image-policy-with-exceptions
spec:
  validationFailureAction: Audit         # Bắt đầu Audit mode
  background: true
  rules:
  - name: check-cve-exceptions
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Image has unpatched CRITICAL CVEs"
      pattern:
        spec:
          containers:
          - image: "registry.example.com/prod/*"
    # Exception patterns
    exceptions:
      - wildcard: "CVE-2024-3200*"     # Tất cả CVE-2024-3200-xxx
      - wildcard: "CVE-2024-1000*"     # Tất cả CVE-2024-1000-xxx
EOF
```

**Step 2 — Tạo policy với certificate-based exception (legacy signer)**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: legacy-app-exception
spec:
  validationFailureAction: Audit
  background: true
  rules:
  - name: allow-legacy-signed-by-old-ci
    match:
      any:
      - resources:
          kinds:
          - Pod
          namespaces:
          - "legacy-ns"
    verifyImages:
    - imageReferences:
      - "registry.example.com/legacy-app:*"
      # Cho phép image được sign bởi old CI (legacy certificate)
      attestors:
      - entries:
        - keyless:
            issuer: https://token.actions.githubusercontent.com
            # Certificate subject của LEGACY CI workflow
            subject: https://github.com/legacy-org/legacy-repo/.github/workflows/old-build.yml@refs/heads/main
            rekor:
              url: https://rekor.sigstore.dev
EOF
```

**Step 3 — Tạo namespace cho legacy app**
```bash
kubectl create ns legacy-ns
```

**Step 4 — Test policy với CVE exception**
```bash
# Giả sử image registry.example.com/prod/api có CVE-2024-3200
# Policy sẽ bỏ qua CVE-2024-3200* nhờ wildcard exception
# → Pod tạo được (Audit mode)

cat <<EOF | kubectl apply -f - --namespace=legacy-ns
apiVersion: v1
kind: Pod
metadata:
  name: prod-api
  namespace: legacy-ns
spec:
  containers:
  - name: api
    image: registry.example.com/prod/api:v1
EOF
```

**Step 5 — Xem PolicyReport để xem exceptions**
```bash
kubectl get policyreport -A
kubectl describe policyreport <name> -n <ns>
# Xem: các CVE nào bị bắt, CVE nào được exception
```

**Step 6 — Test: chuyển legacy policy sang Enforce**
```bash
kubectl patch clusterpolicy legacy-app-exception \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'

# Bây giờ:
# - Image sign bởi old CI → cho phép
# - Image không sign → bị deny
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| Policy `image-policy-with-exceptions` | Active, Audit mode |
| Policy `legacy-app-exception` | Active (chuyển sang Enforce ở Step 6) |
| CVE-2024-3200* | Được bỏ qua (wildcard exception) |
| CVE-2024-9999 (không trong exception) | Được báo vi phạm |
| Legacy image sign bởi old CI | Cho phép (certificate match) |
| Legacy image không sign | Bị deny (Enforce mode) |

---

## Bonus Lab — End-to-End: CI scan → sign → deploy

**Mục tiêu:** Tạo full supply chain pipeline: build → Trivy scan → Cosign sign → Deploy qua Kyverno verify.

**Điều kiện tiên quyết:** Hoàn thành Lab 5, 6, 8.

### Các bước thực hiện

**Step 1 — Tạo GitHub Actions workflow đầy đủ**
```yaml
# .github/workflows/supply-chain.yml
name: Supply Chain Security Pipeline

on:
  push:
    branches: [main]

jobs:
  build-scan-sign:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write        # Cần cho OIDC (keyless signing)
      security-events: write # Để upload SARIF

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        id: build
        uses: docker/build-push-action@v5
        with:
          context: .
          tags: ghcr.io/${{ github.repository_owner }}/demo-e2e:${{ github.sha }}
          push: true
          cache-from: type=registry,ref=ghcr.io/${{ github.repository_owner }}/demo-e2e:buildcache
          cache-to: type=registry,ref=ghcr.io/${{ github.repository_owner }}/demo-e2e:buildcache,mode=max

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign image (keyless OIDC)
        run: |
          cosign sign --yes ${{ steps.build.outputs.tags }}
        env:
          COSIGN_EXPERIMENTAL: "1"

      - name: Run Trivy scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: '${{ steps.build.outputs.tags }}'
          format: sarif
          output: trivy-results.sarif
          severity: CRITICAL,HIGH
          exit-code: '1'

      - name: Upload Trivy SARIF
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: trivy-results.sarif

  deploy:
    needs: build-scan-sign
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to K8s
        run: |
          kubectl set image deployment/ci-signed-app \
            app=ghcr.io/${{ github.repository_owner }}/demo-e2e:${{ github.sha }} \
            -n supply-chain-lab
```

**Step 2 — Chạy pipeline**
```bash
git add .github/workflows/supply-chain.yml Dockerfile
git commit -m "Add full supply chain security pipeline"
git push origin main
```

**Step 3 — Theo dõi pipeline chạy**
- Vào GitHub → Actions → xem `Supply Chain Security Pipeline`
- Expected flow:
  1. Build image → push GHCR
  2. Cosign sign (keyless OIDC) → signature trong GHCR
  3. Trivy scan → SARIF upload vào Security tab
  4. Deploy → Kyverno verify signature → cho phép

**Step 4 — Verify deployment**
```bash
kubectl get pods -n supply-chain-lab
# Pod mới chạy image vừa sign + scan

kubectl get policyreport -n supply-chain-lab
# PolicyReport hiển thị verifyImages pass
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| GitHub Actions | Build → Scan → Sign → Deploy thành công |
| Security > Code scanning | SARIF results từ Trivy |
| GHCR | Image có signature artifact |
| K8s Pod | Running với image vừa deploy |
| PolicyReport | `verifyImages` pass |
| Kyverno logs | Không có deny errors |

---

## Cleanup

Sau khi hoàn thành tất cả labs, dọn dẹp resources:

```bash
# K8s namespaces
kubectl delete ns supply-chain-lab legacy-ns

# Kyverno
helm uninstall kyverno -n kyverno
kubectl delete ns kyverno

# ESO
helm uninstall external-secrets -n external-secrets
kubectl delete ns external-secrets

# AWS (xóa secret)
aws secretsmanager delete-secret --secret-id supply-chain/db-password --force-delete-without-recovery

# IAM
aws iam detach-role-policy --role-name ESO-SecretsManager-Role --policy-arn <POLICY_ARN>
aws iam delete-role --role-name ESO-SecretsManager-Role
aws iam delete-policy --policy-arn <POLICY_ARN>

# Local files
rm -f cosign.key cosign.pub iam-policy-eso.json trust-policy.json
rm -f trivy-results.json trivy-results.sarif
```

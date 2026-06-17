# Day-2 Keys — Secrets Rotation + Supply Chain Security

Tổng hợp những điểm then chốt cần nhớ sau mỗi section. Dùng để ôn tập nhanh.

---

## Section 1 — AWS Secrets Manager + ESO Keys

### AWS Secrets Manager — Khái niệm cốt lõi

| Khái niệm | Giải thích |
|-----------|-----------|
| Secret | Object lưu credentials, encrypted bằng KMS |
| Rotation | Lambda tự động đổi secret định kỳ (Lambda → CreateSecret → SetSecret → TestSecret → FinishSecret) |
| KMS Encryption | Tất cả secret đều encrypted — ai không có KMS key policy thì không đọc được |
| Resource policy | Attach policy vào secret để control ai access (IAM, Lambda, ESO) |

### External Secrets Operator — 3 CRD chính

```
ExternalSecret (ES)         SecretStore (SS)         ClusterSecretStore (CSS)
    ├── spec.refreshInterval    ├── spec.provider        ├── Giống SS nhưng
    ├── spec.secretStoreRef      ├── spec.aws             │   cluster-wide
    │   └── name + kind          └── spec.service(IRSA)  └── Dùng khi nhiều
    └── spec.target.name                                    namespaces cần
         └── tạo K8s Secret           ns cần secret           cùng store
```

| CRD | Scope | Dùng khi |
|-----|-------|---------|
| `ExternalSecret` | Namespace | Một namespace cần sync 1 secret |
| `SecretStore` | Namespace | Kết nối đến provider trong ns đó |
| `ClusterSecretStore` | Cluster-wide | Nhiều namespaces dùng chung provider |

### ExternalSecret spec — Fields quan trọng

```yaml
spec:
  refreshInterval: "10s"           # Re-sync interval (default 1h, min 1s)
  secretStoreRef:                  # Trỏ đến SecretStore/ClusterSecretStore
    name: aws-backend
    kind: ClusterSecretStore
  target:
    name: my-db-secret             # Tên K8s Secret output
    creationPolicy: Owner          # Owner (xóa khi ES bị xóa) | Merge | None
  data:
    - secretKey: password          # Key trong K8s Secret output
      remoteRef:
        key: myapp/db-password     # Key/name trong AWS Secrets Manager
        property: password         # Optional: lấy field cụ thể trong JSON secret
```

### Rotation flow

```
AWS Secrets Manager          Lambda Rotation
    ├── Rotation schedule            ├── Đọc current secret
    │   └── 30 ngày / tự định        ├── Tạo new secret version
    ├── Lambda trigger               ├── Test new secret (TestSecret)
    └── Rotate → Version incremented └── FinishSecret → active
                                            ↓
                                    ESO detect version change
                                    → re-sync via refreshInterval
                                    → update K8s Secret
```

### Lưu ý quan trọng
- ESO **sync** secret — không tự rotate. Rotation do AWS (Lambda) làm.
- `refreshInterval` quyết định bao lâu K8s Secret được cập nhật. Lab: "10s", Production: "1h".
- K8s Secret được tạo bởi ESO có label `app.kubernetes.io/managed-by: external-secrets`.

---

## Section 2 — AWS IAM + ESO Lab Keys

### IAM cho ESO — IRSA Pattern (EKS)

```
IAM Role: external-secrets-sa-role
    ├── Trust Policy: cho phép OIDC principal assumeRole
    │   └── sts:AssumeRoleWithWebIdentity
    │       └── Condition: StringEquals:
    │           oidc.eks.region.amazonaws.com/id/<cluster-id>:sub
    │             system:serviceaccount:external-secrets:external-secrets-sa
    └── Policy: secretsmanager:GetSecretValue, secretsmanager:DescribeSecret
         └── Resource: arn:aws:secretsmanager:region:account:secret:myapp/*
```

### ServiceAccount annotation (IRSA)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  namespace: external-secrets
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456:role/external-secrets-sa-role
```

### ClusterSecretStore YAML

```yaml
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
```

### Verify commands

```bash
kubectl get clusterssecretstore    # xem ClusterSecretStore
kubectl get externalsecret -A       # xem ES trong tất cả namespaces
kubectl describe externalsecret <name> -n <ns>  # xem sync status
kubectl get secret <target-name> -n <ns> -o jsonpath='{.data.<key>}' | base64 -d
```

---

## Section 3 — Trivy Keys

### Trivy scan types

| Command | Scan type | Use case |
|---------|----------|---------|
| `trivy image nginx:1.25` | Container image | Scan remote image từ registry |
| `trivy fs ./` | Filesystem | Scan local files (Dockerfile, package.json, go.mod) |
| `trivy config ./k8s/` | IaC config | Scan K8s YAML, Terraform, Helm |
| `trivy repo https://github.com/org/repo` | Git repo | Scan code + dependencies |

### Severity levels

```
CRITICAL > HIGH > MEDIUM > LOW > UNKNOWN
```

### Trivy trong CI — Key flags

```bash
trivy image \
  --severity CRITICAL,HIGH \       # Chỉ báo CVE ở mức này trở lên
  --exit-code 1 \                  # Exit 1 nếu tìm thấy vuln (fail build)
  --format sarif \                 # Output format (SARIF cho GitHub Security)
  --ignorefile .trivyignore \      # File ignore CVE
  myapp:${{ github.sha }}
```

### SARIF output

- SARIF = Static Analysis Results Interchange Format
- GitHub có thể đọc SARIF và hiển thị trong **Security > Code scanning alerts**
- Upload SARIF: `gh codeql --sarif upload` hoặc GitHub Action `github/codeql-action/upload-sarif`

### .trivyignore format

```
# Comment
CVE-2024-1234
CVE-2024-5678  # With reason
CVE-2024-9999
```

### Trivy exit codes

| Exit code | Meaning |
|-----------|---------|
| 0 | Không có vulnerabilities |
| 1 | Có vulnerabilities (dùng trong CI để fail) |
| 2 | Lỗi (image không tồn tại, network error) |

---

## Section 4 — Cosign Keys

### Sigstore Ecosystem

```
Fulcio CA          Rekor (Transparency Log)         Cosign
    ├── OIDC certificate              ├── Ghi lại mọi        ├── Sign/Verify
    │   issuer (free)                 │   signing events     ├── Attestation
    ├── Short-lived cert               ├── Immutable          └── Policy
    └── No key management              └── Public/auditable
```

### Keyless vs Key-based — So sánh

| Tiêu chí | Keyless (OIDC) | Key-based |
|---------|---------------|-----------|
| Private key | Tạm (in-memory, không lưu) | Cần quản lý (`cosign.key`) |
| Identity | OIDC (GitHub Actions, Google, Azure) | Key fingerprint |
| Certificate | Short-lived (Fulcio) | Long-lived (self-signed hoặc CA) |
| Transparency log | Rekor (recommended) | Optional |
| Offline signing | Không | Có thể |
| Complexity | Thấp | Cao (key storage/rotation) |
| Khuyến nghị | ✅ Production | Cần key management solution |

### Keyless OIDC Flow

```
cosign sign <image>
    │
    ├── 1. Lấy OIDC token từ environment
    │       (GitHub Actions: ACTIONS_ID_TOKEN_REQUEST_TOKEN)
    │
    ├── 2. Gửi token → Fulcio CA
    │       → Nhận short-lived X.509 certificate
    │
    ├── 3. Sign image bằng private key tạm
    │       → Tạo signature + certificate
    │
    ├── 4. Upload signature + certificate vào registry
    │       (cùng image name, khác tag: sha256-...)
    │
    └── 5. Ghi vào Rekor transparency log
            → Immutable record của signing event
```

### Cosign — Key commands

```bash
# Keyless sign (OIDC — cần login trước)
cosign sign <registry>/<image>:<tag>
# Trong CI: cosign sign --yes <image> (--yes = không prompt)

# Key-based sign
cosign generate-key-pair                    # Tạo cosign.key + cosign.pub
cosign sign --key cosign.key <image>

# Verify (keyless)
cosign verify <image>
cosign verify \
  --certificate-identity-regexp "https://github.com/.*" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  <image>

# Verify (key-based)
cosign verify --key cosign.pub <image>

# Xem signature/attestation
cosign tree <image>
cosign triangulate <image>  # Xem signature location
```

### Attestation vs Signature

| | Signature | Attestation |
|--|-----------|-------------|
| Purpose | Chứng minh image được sign | Chứng minh điều kiện build (SBOM, SLSA) |
| Type | `signature` | `attestation` |
| Example | "Image được sign bởi CI" | "Image passed Trivy scan, SBOM attached" |
| Command | `cosign sign` | `cosign attest` |

### Registry hỗ trợ Cosign

Docker Hub, AWS ECR, GCP GCR/Acr, GitHub GHCR, GitLab Registry, Azure ACR

---

## Section 5 — Kyverno verifyImages Keys

### Kyverno verifyImages — Kiến trúc

```
Pod/Deployment CREATE
    │
    ├── MutatingAdmissionWebhook (Kyverno)
    │       └── verifyImages rule:
    │           1. Tìm image cần verify
    │           2. Pull signature từ registry
    │           3. Check certificate identity
    │           4. Check Rekor log entry
    │           5. Inject signature annotation vào pod spec
    │
    └── ValidatingAdmissionWebhook (Kyverno)
            └── verifyImages rule:
                1. Re-verify signature đã inject
                2. Check attestations (nếu có)
                3. Pass → cho tạo
                4. Fail → reject (403)
```

### Attestor types

**Keyless attestor:**

```yaml
attestors:
- entries:
  - keyless:
      # OIDC issuer — Fulcio CA hoặc custom OIDC provider
      issuer: https://token.actions.githubusercontent.com

      # Certificate subject — xác định WHO đã sign
      # GitHub Actions format:
      subject: https://github.com/<org>/<repo>/.github/workflows/<workflow>.yml@refs/heads/<branch>

      # Rekor server (transparency log)
      rekor:
        url: https://rekor.sigstore.dev

      # Optional: issuer với tên (để log)
      issuerRegExp: https://token.actions.githubusercontent.com
```

**Key-based attestor:**

```yaml
attestors:
- entries:
  - key:
      # Public key dạng string
      publicKey: |
        -----BEGIN PUBLIC KEY-----
        ...
        -----END PUBLIC KEY-----

      # Hoặc trỏ đến K8s Secret chứa public key
      # secretRef:
      #   name: cosign-public-key
      #   namespace: verify-images
```

### verifyImages — Policy structure

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce   # Enforce = reject | Audit = log only
  background: true                    # Scan existing resources
  webhookTimeoutSeconds: 10
  failurePolicy: Fail
  rules:
  - name: verify-signed
    match:
      any:
      - resources:
          kinds:
          - Pod
    verifyImages:
    - imageReferences:
      # Image cần verify (support wildcard)
      - "registry.example.com/*"
      - "ghcr.io/myorg/*"
      # Có thể exclude:
      # - "registry.example.com/legacy/*"
      attestors:
      - entries:
        - keyless:
            issuer: https://token.actions.githubusercontent.com
            subject: https://github.com/myorg/myrepo/.github/workflows/build.yml@refs/heads/main
            rekor:
              url: https://rekor.sigstore.dev
```

### Certificate Identity matching

| Field | Giải thích | Ví dụ |
|-------|------------|-------|
| `issuer` | OIDC token issuer | `https://token.actions.githubusercontent.com` |
| `subject` | OIDC token subject | `https://github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main` |
| `issuerRegExp` | Regex cho issuer | `https://.*actions.githubusercontent.com` |
| `subjectRegExp` | Regex cho subject | `https://github.com/org/.*` |

### failureActions trong Kyverno

| Action | Hành vi khi verify fail |
|--------|------------------------|
| `Enforce` | Reject request → Pod không được tạo |
| `Audit` | Log violation → Pod vẫn được tạo |

### Lưu ý
- Kyverno verifyImages cần Kyverno >= 1.10
- Image phải có signature trong registry — verify fail nếu chưa sign
- Background mode (`background: true`) — scan existing pods, không chỉ intercept new

---

## Section 6 — CVE Exception + SLSA Keys

### CVE Exception patterns

**Kyverno wildcard exception:**

```yaml
# Exception cho cụm CVE theo pattern
exceptions:
  - wildcard: "CVE-2024-*"       # Tất cả CVE-2024-xxx
  - wildcard: "GHSA-*"           # GitHub Security Advisory
```

**Certificate-based exception:**

```yaml
# Cho phép image từ specific certificate identity (legacy signer)
verifyImages:
- imageReferences:
  - "registry.example.com/legacy-app:*"
  attestors:
  - entries:
    - keyless:
        issuer: https://token.actions.githubusercontent.com
        subject: https://github.com/legacy-org/legacy-repo/.github/workflows/old-build.yml@refs/heads/main
```

**Trivy ignore:**

```
# .trivyignore
CVE-2024-1234
CVE-2024-5678  # Legacy Alpine package, fix Q3 2025
GHSA-xxxx-xxxx-xxxx
```

### SLSA Framework

| Level | Tên | Build service | Provenance | Signed | Hermetic |
|-------|-----|--------------|-----------|--------|---------|
| L1 | Source | Version controlled | Generated | No | No |
| L2 | Service | Hosted (e.g., GitHub Actions) | Hosted | No | No |
| L3 | Hardened | Hardened (isolated, ephemeral) | Signed | Yes | Yes |
| L4 | Reviewable | Hardened + review | Signed + reviewable | Yes | Yes |

**Hermetic** = build không cần network access
**Ephemeral** = build chạy trên clean environment mỗi lần
**Isolated** = build không access từ bên ngoài

### SLSA + Cosign

```
Cosign attest --predicate slsa-provenance.json --type slsa.provenance <image>
    ↓
Ghi provenance vào registry (dạng attestation)
    ↓
Kyverno verifyImages có thể verify SLSA attestation:
    attestations:
    - name: slsa
      attestors:
      - entries:
        - keyless:
            issuer: ...
```

### Full Supply Chain Flow (end-to-end)

```
[Developer] push code → GitHub
    ↓
[CI: GitHub Actions]
  ├── Trivy scan → fail nếu CRITICAL/HIGH
  ├── docker build → docker push
  ├── cosign sign (keyless OIDC) → sign image
  └── cosign attest --type slsa.provenance → attach SBOM
    ↓
[K8s: Kyverno Admission]
  ├── verifyImages: check signature (Cosign)
  ├── verifyImages: check certificate identity (OIDC match)
  ├── verifyImages: check SLSA attestation
  └── Pass → Deploy | Fail → Reject
    ↓
[Runtime: ESO]
  ├── AWS Secrets Manager → encrypted secret
  ├── ESO refreshInterval → sync → K8s Secret
  └── Pod mount K8s Secret → access credentials
```

---

## Quick Reference Commands

### AWS CLI
```bash
aws secretsmanager create-secret --name myapp/db-password --secret-string '{"user":"admin","pass":"xxx"}'
aws secretsmanager get-secret-value --secret-id myapp/db-password
aws secretsmanager list-secrets
```

### ESO
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <ns>
kubectl get secret <target-name> -n <ns>
```

### Trivy
```bash
trivy image nginx:1.25
trivy image --severity CRITICAL,HIGH --exit-code 1 nginx:alpine
trivy image --format sarif --output results.sarif myapp:latest
trivy fs ./ --scanners vuln,secret,config
trivy k8s cluster --report summary
```

### Cosign
```bash
# Install
go install github.com/sigstore/cosign/v2/cmd/cosign@latest

# Keyless sign (cần OIDC login)
cosign login ghcr.io
cosign sign --yes ghcr.io/myorg/myapp:latest

# Key-based
cosign generate-key-pair
cosign sign --key cosign.key ghcr.io/myorg/myapp:latest

# Verify
cosign verify ghcr.io/myorg/myapp:latest
cosign verify --key cosign.pub ghcr.io/myorg/myapp:latest
cosign tree ghcr.io/myorg/myapp:latest
```

### Kyverno
```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

kubectl get clusterpolicy
kubectl describe clusterpolicy <name>
kubectl get policyreport -A              # Audit results
kubectl logs -n kyverno -l app.kubernetes.io/component=background-controller
```

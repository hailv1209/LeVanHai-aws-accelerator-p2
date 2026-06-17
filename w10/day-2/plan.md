# Day-2 Study Plan: Secrets Rotation + Supply Chain Security

**Thời lượng ước tính:** 3.5–4 giờ (tự học)
**Điều kiện tiên quyết:** Day-1 hoàn thành (K8s cluster + kubectl + kubectl access), có AWS account (free tier đủ), có Docker local.

---

## Chuẩn bị môi trường

Trước khi bắt đầu, đảm bảo bạn có:

- Kubernetes cluster (kind/minikube/EKS/GKE)
- `kubectl` đã cấu hình context
- Docker desktop đang chạy
- AWS account (free tier) + AWS CLI cấu hình (`aws configure`)
- GitHub account (để dùng trong CI lab Trivy + Cosign)
- `cosign` binary installed: `go install github.com/sigstore/cosign/v2/cmd/cosign@latest`
- `trivy` binary installed: `brew install trivy` (macOS) hoặc download từ GitHub releases

---

## Section 1 — AWS Secrets Manager cơ bản + ESO overview (45 phút)

### Mục tiêu
Hiểu AWS Secrets Manager làm gì, External Secrets Operator (ESO) giải quyết vấn đề gì, và các khái niệm cốt lõi: SecretStore, ExternalSecret, refreshInterval.

### Thứ tự học

1. **AWS Secrets Manager docs:** https://docs.aws.amazon.com/secretsmanager/latest/userguide/what-is-secrets-manager.html
   - Đọc phần "How Secrets Manager works"
   - Focus: Secret, rotation, Lambda rotation function
   - Hiểu: Secrets Manager lưu secret encrypted (KMS), không expose plaintext cho K8s pod trực tiếp

2. **External Secrets Operator (ESO) docs:** https://external-secrets.io/latest
   - Đọc phần "Getting Started" → "Concepts"
   - Hiểu vấn đề: K8s không nên hardcode secret values trong GitOps → cần sync từ external secret store
   - **ESO Architecture:**
     ```
     ExternalSecret (ES) — user declarative CRD, spec what secret to fetch
         ↓
     SecretStore (SS) — connection config đến provider (AWS, GCP, Vault...)
         ↓
     Provider (AWS Secrets Manager) — actual secret store
     ```
   - `refreshInterval`: khoảng thời gian ESO re-sync secret từ provider → K8s Secret (mặc định 1h, có thể set 10s cho lab)
   - Kiểu `ExternalSecret` output → tạo ra một `kubernetes.io/v1 Secret` trong namespace target

3. **Đọc phần CRD spec của ESO:** https://external-secrets.io/latest/api/externalsecret/
   - Focus fields: `spec.refreshInterval`, `spec.secretStoreRef`, `spec.target.name`, `spec.target.creationPolicy`

### Check-point — tự hỏi mình trước khi qua Section 2

- [ ] Secrets Manager lưu secret ở đâu? Ai access được?
- [ ] ESO gồm những CRD chính? (ExternalSecret, SecretStore, ClusterSecretStore)
- [ ] `refreshInterval` dùng để làm gì? Mặc định là bao nhiêu?
- [ ] ExternalSecret tạo ra resource gì trong K8s? (Kubernetes Secret)
- [ ] Tại sao không dùng Secrets Manager SDK trực tiếp trong app mà dùng ESO?

---

## Section 2 — AWS Secrets Manager: Tạo secret + IAM role + ESO sync lab (45 phút)

### Mục tiêu
Tạo một secret trong AWS Secrets Manager, cấu hình IAM permission, install ESO, tạo SecretStore + ExternalSecret, và verify secret được sync vào K8s.

### Thứ tự học

1. **AWS Secrets Manager — tạo secret qua CLI:**
   ```
   aws secretsmanager create-secret \
     --name myapp/db-password \
     --description "DB password for myapp" \
     --secret-string '{"username":"admin","password":"SuperSecret123!"}'
   ```
   - Verify: `aws secretsmanager get-secret-value --secret-id myapp/db-password`

2. **AWS Secrets Manager — Rotation (khái niệm):**
   - Đọc: https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html
   - Rotation = Lambda tự động đổi secret định kỳ
   - Rotation function gọi `CreateSecret` → `SetSecret` → `TestSecret` → `FinishSecret`
   - Hiểu: ESO chỉ *sync*, không tự rotate — rotation do AWS Secrets Manager (Lambda) thực hiện

3. **IAM cho ESO — cấu hình permission:**
   - ESO chạy trong K8s, cần IAM permission để đọc Secrets Manager
   - Hai cách: IAM Role for Service Account (IRSA) trên EKS, hoặc AWS credentials trong SecretStore
   - IRSA pattern (EKS):
     ```
     OIDC provider → IAM Role → trust policy cho ServiceAccount
     SA → ESO pod → assume role → get-secret-value
     ```
   - Policy cần: `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret`

4. **ESO — Install:**
   ```bash
   helm repo add external-secrets https://charts.external-secrets.io
   helm install external-secrets external-secrets/external-secrets \
     --namespace external-secrets --create-namespace
   ```

5. **ESO — ClusterSecretStore + ExternalSecret YAML:**
   - `ClusterSecretStore`: kết nối đến AWS Secrets Manager (dùng IRSA)
   - `ExternalSecret`: specify secret cần sync
   - Focus fields trong spec:
     - `spec.refreshInterval`: "10s" cho lab (production: "1h")
     - `spec.secretStoreRef.name`: trỏ đến ClusterSecretStore
     - `spec.target.name`: tên K8s Secret output
     - `spec.data[].secretKey`: key bên trong AWS secret
     - `spec.data[].remoteRef.key`: path/key trong AWS Secrets Manager

6. **Verify:**
   ```bash
   # Xem ExternalSecret đã sync chưa
   kubectl get externalsecret -n <ns>
   kubectl describe externalsecret <name> -n <ns>

   # Xem K8s Secret được tạo
   kubectl get secret <target-name> -n <ns>
   kubectl get secret <target-name> -n <ns> -o jsonpath='{.data.username}' | base64 -d
   ```

### Check-point

- [ ] Secret trong AWS Secrets Manager có dùng `aws secretsmanager get-secret-value` đọc được?
- [ ] ESO pod đang chạy trong namespace `external-secrets`?
- [ ] ExternalSecret status là `Ready` (không `SecretSyncedError`)?
- [ ] K8s Secret được tạo với đúng data từ AWS?
- [ ] `refreshInterval: "10s"` có nghĩa là sau 10s ESO sẽ re-sync?

---

## Section 3 — Trivy: Image scan trong CI (45 phút)

### Mục tiêu
Hiểu Trivy scan container image như thế nào, các loại scan (image, fs, config), severity levels, cách dùng trong CI pipeline (GitHub Actions), và cách fail build khi có CVE nghiêm trọng.

### Thứ tự học

1. **Trivy docs:** https://aquasecurity.github.io/trivy
   - Đọc phần "Getting Started" và "Usage"
   - Trivy là static analysis tool cho container images, filesystem, git repo, SBOM
   - **Scan types quan trọng:**
     - `trivy image <image>` — scan remote image (qua registry)
     - `trivy fs <path>` — scan local filesystem (Dockerfile, dependencies)
     - `trivy config <path>` — scan IaC config (Terraform, K8s YAML, Helm)
     - `trivy repo <url>` — scan git repository

2. **Severity levels:** `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, `UNKNOWN`
   - Trivy exit code: 0 = no vulns, 1 = vulns found
   - `--exit-code 1 --severity CRITICAL,HIGH` → fail nếu có CRITICAL hoặc HIGH

3. **Trivy output formats:**
   - `table` (default) — human-readable
   - `json` — machine-readable
   - `sarif` — SARIF format (GitHub Security tab có thể đọc)
   - `template` — custom output

4. **Trivy trong CI — GitHub Action:**
   - Tìm hiểu: https://github.com/aquasecurity/trivy-action
   - Typical CI workflow:
     ```yaml
     - name: Build image
       run: docker build -t myapp:${{ github.sha }} .
     - name: Run Trivy
       uses: aquasecurity/trivy-action@master
       with:
         image-ref: myapp:${{ github.sha }}
         format: sarif
         output: trivy-results.sarif
         severity: CRITICAL,HIGH
         exit-code: '1'  # fail build nếu có CRITICAL/HIGH
     - name: Upload results
       uses: github/codeql-action/upload-sarif@v3
         with: { sarif_file: trivy-results.sarif }
     ```
   - Upload SARIF → GitHub Security tab hiển thị vulnerabilities

5. **Trivy — Ignore/unignore policy:**
   - `.trivyignore` file — ignore specific CVE IDs (giống `.gitignore`)
   - Format: mỗi dòng là CVE ID (e.g., `CVE-2024-1234`)
   - Hoặc dùng `--ignorefile` flag

### Check-point

- [ ] `trivy image nginx:1.25` chạy được và liệt kê vulnerabilities?
- [ ] `trivy image --severity CRITICAL nginx:1.25` chỉ hiện CRITICAL vulns?
- [ ] `trivy image --exit-code 1 --severity CRITICAL,HIGH nginx:alpine` có exit code 1?
- [ ] Hiểu `--format sarif` dùng để làm gì trong CI?
- [ ] `.trivyignore` cho phép ignore CVE nào?

---

## Section 4 — Cosign signing: Keyless OIDC + Key-based (60 phút)

### Mục tiêu
Hiểu Sigstore ecosystem, cách Cosign sign container images (keyless OIDC flow và key-based signing), và verify signature.

### Thứ tự học

1. **Cosign / Sigstore docs:** https://docs.sigstore.dev/cosign/overview
   - Sigstore = free signing service cho software supply chain
   - Cosign = CLI tool để sign và verify container images
   - Fulcio = certificate authority (OIDC-based, free)
   - Rekor = transparency log (ghi lại mọi signature)

2. **Keyless signing (OIDC flow) — khuyến nghị:**
   ```
   cosign sign <image>
   ```
   - Flow:
     1. Cosign lấy OIDC token từ environment (GitHub Actions OIDC token, hoặc `cosign login` locally)
     2. Gửi token đến Fulcio CA → nhận short-lived certificate
     3. Sign image bằng private key tạm (chỉ trong memory)
     4. Upload signature vào registry cùng image
     5. Ghi certificate + signature vào Rekor transparency log
   - **Không cần quản lý private key** — OIDC token làm identity
   - Verify: `cosign verify <image>` — check signature + certificate + Rekor log

3. **Key-based signing:**
   - Tạo keypair: `cosign generate-key-pair`
   - Output: `cosign.key` (private) + `cosign.pub` (public)
   - Sign: `cosign sign --key cosign.key <image>`
   - Verify: `cosign verify --key cosign.pub <image>`
   - Lưu private key an toàn (Nên dùng KMS/HashiCorp Vault cho production)

4. **So sánh Keyless vs Key-based:**

| Tiêu chí | Keyless (OIDC) | Key-based |
|---------|---------------|-----------|
| Private key | Không cần (temporary, in-memory) | Cần quản lý |
| Identity | OIDC (GitHub, Google, Azure AD) | Key fingerprint |
| Certificate | Short-lived (Fulcio) | Long-lived (self-signed hoặc CA) |
| Transparency log | Rekor (khuyến nghị) | Optional |
| Complexity | Thấp (không cần key management) | Cao (cần secure key storage) |
| Production use | Khuyến nghị | Cần key management solution |
| Offline signing | Không được | Có thể |

5. **Cosign — Verify options:**
   ```bash
   # Keyless verify (default)
   cosign verify <image>

   # Verify với certificate identity
   cosign verify \
     --certificate-identity-regexp "https://github.com/.*" \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     <image>

   # Key-based verify
   cosign verify --key cosign.pub <image>
   ```

6. **Image signature storage:**
   - Cosign upload signature vào registry như artifact (đồng image name, khác tag)
   - Registry phải hỗ trợ: Docker Hub, ECR, GCR, GHCR, ACR

### Check-point

- [ ] Giải thích được keyless OIDC flow (4 bước: token → Fulcio → sign → Rekor)?
- [ ] Keyless cần quản lý private key không? Tại sao?
- [ ] Rekor transparency log làm gì?
- [ ] `cosign.pub` dùng để verify key-based signature — private key đâu?
- [ ] Khi nào dùng key-based thay vì keyless?

---

## Section 5 — Kyverno verifyImages: Admission webhook verify signature (45 phút)

### Mục tiêu
Hiểu Kyverno `verifyImages` rule chạy như admission webhook, cách cấu hình để chỉ cho phép image đã được Cosign sign, và certificate identity matching.

### Thứ tự học

1. **Kyverno docs — verifyImages:** https://kyverno.io/policies/?policytypes=verifyImages
   - `verifyImages` là loại policy đặc biệt trong Kyverno
   - Chạy như **MutatingAdmissionWebhook** (điều chỉnh image) + **ValidatingAdmissionWebhook** (verify)
   - Workflow:
     ```
     Pod/Deployment tạo → Kyverno intercept
         ↓
     verifyImages rule check:
     1. Image đã sign chưa?
     2. Certificate identity match không?
     3. Attestation (SBOM/SLSA) có hợp lệ không?
         ↓
     Pass → cho tạo
     Fail → reject (403)
     ```

2. **Kyverno verifyImages — Cấu trúc policy:**
   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: check-image-signature
   spec:
     validationFailureAction: Enforce  # hoặc Audit
     background: true
     rules:
     - name: verify-signed-images
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "registry.example.com/*"
         attestors:
         - entries:
           - keyless:
               # Keyless OIDC config
               issuer: https://token.actions.githubusercontent.com
               subject: https://github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main
               rekor:
                 url: https://rekor.sigstore.dev
   ```

3. **Attestor types:**
   - **Keyless:** Dùng OIDC + Fulcio certificate (không cần public key)
     - `keyless.issuer` — OIDC issuer URL
     - `keyless.subject` — certificate subject (thường là GitHub workflow path)
     - `keyless.rekor.url` — Rekor server
   - **Key-based:** Dùng public key
     - `key.publicKey` — path đến public key file trong K8s
     - Hoặc `key.secretRef` — secret chứa public key

4. **Certificate Identity matching:**
   - `certificateIdentity` — kiểm tra certificate extension trong signature
   - Dùng để đảm bảo image được sign bởi đúng CI workflow/account
   - Ví dụ: chỉ cho phép image sign bởi GitHub Actions của repo `org/repo`

5. **Kyverno verifyImages — failure actions:**
   - `Enforce` → reject request nếu verify fail
   - `Audit` → log violation nhưng vẫn cho tạo (để test trước)

### Check-point

- [ ] `verifyImages` rule chạy ở phase nào? (Mutating/Validating admission webhook)
- [ ] Sự khác biệt giữa `keyless` và `key` attestor?
- [ ] `issuer` và `subject` dùng để làm gì trong keyless config?
- [ ] `validationFailureAction: Audit` khác `Enforce` như thế nào?
- [ ] Attestor check trước khi Pod được tạo — nếu image chưa sign thì sao?

---

## Section 6 — CVE Exception Policy + SLSA (30 phút)

### Mục tiêu
Hiểu cách xử lý CVE exceptions trong supply chain security: wildcard ignore, certificate-based exception, và framework SLSA.

### Thứ tự học

1. **CVE Exception trong Kyverno:**
   - Khi policy `verifyImages` hoặc Trivy fail, có thể cần exception cho một số CVE
   - Pattern exception trong Kyverno:
     ```yaml
     # Exception cho một CVE cụ thể
     - name: allow-cve-exception
       match:
         any:
         - resources:
             namespaces: ["legacy-app"]
       validate:
         message: "Only CRITICAL CVEs are blocked"
         pattern:
           spec:
             containers:
             - image: "registry.example.com/legacy-app:*"
       exceptions:
         - CVE-2024-1234  # wildcard exception
     ```
   - Hoặc dùng `wildcard` pattern:
     ```yaml
     exceptions:
       - wildcard: "CVE-2024-*"  # ignore all CVE-2024-xxx
     ```

2. **Certificate-based exception:**
   - Dùng `certificateIdentity` để tạo exception cho image từ specific signer
   - Ví dụ: legacy app được sign bởi old CI → tạo exception cho certificate identity cũ

3. **Trivy ignore trong CI:**
   - `.trivyignore` file — ignore specific CVE IDs
   - Hoặc dùng `--ignore-policy` flag với custom ignore policy
   - Format:
     ```
     # Ignore specific CVE
     CVE-2024-5678

     # Ignore with reason (comment)
     CVE-2024-9999  # Legacy dependency, fix scheduled for Q3
     ```

4. **SLSA Framework (Supply chain Levels for Software Artifacts):** https://slsa.dev
   - SLSA = framework để đảm bảo integrity của software supply chain
   - **4 Levels:**
     - **SLSA 1:** Build script + provenance (documentation)
     - **SLSA 2:** Version controlled build service + hosted provenance (e.g., GitHub Actions)
     - **SLSA 3:** Hardened build service + signed provenance (Hermetic, Ephemeral, Isolated)
     - **SLSA 4:** Hardened build service + reviewable + signed provenance (highest level)
   - **Use case:** Đảm bảo artifact được build đúng cách, không bị tamper
   - **Relation với Cosign:** Cosign sign → tạo attestation (SBOM/SLSA provenance) → Kyverno verify attestation

5. **Full Supply Chain Security Flow:**
   ```
   Developer push code
       ↓
   CI (GitHub Actions):
     1. Trivy scan → fail nếu CRITICAL
     2. Build image
     3. Cosign sign (keyless OIDC) → attestation
       ↓
   K8s Deployment:
     Kyverno verifyImages admission webhook:
     - Image signed?
     - Certificate identity match?
     - Attestation valid?
       ↓
   Pass → Deploy | Fail → Reject
   ```

### Check-point

- [ ] `.trivyignore` dùng để ignore CVE nào? Làm sao biết CVE ID?
- [ ] Certificate-based exception trong Kyverno dùng field nào?
- [ ] SLSA có 4 levels — SLSA 3 và SLSA 4 khác nhau ở điểm gì?
- [ ] Full supply chain flow từ push code → deploy? (CI scan → sign → admission verify)

---

## Section 7 — Tổng kết + So sánh công cụ (15 phút)

### Mục tiêu
Tổng hợp toàn bộ kiến thức, hiểu khi nào dùng tool nào trong supply chain security.

### Thứ tự học

1. **Đọc `keys.md`** — ôn lại toàn bộ keys của 6 section
2. **Bảng so sánh tổng quan các công cụ:**

| Tiêu chí | AWS Secrets Manager | ESO | Trivy | Cosign | Kyverno |
|---------|---------------------|-----|-------|--------|---------|
| Mục đích | Lưu secret encrypted | Sync secret vào K8s | Scan vulnerabilities | Sign container image | Admission policy |
| Chạy ở đâu | AWS (cloud) | K8s cluster | CI / local | CI / local | K8s cluster |
| Input | Secret value | External store | Image / fs / repo | Image + private key | Image + signature |
| Output | Encrypted secret | K8s Secret | Vulnerability report | Signed image | Allow/Deny |
| Failure mode | Secret không access | Sync fail (k8s secret stale) | Build fail | Sign fail | Pod reject |
| Rotation | Built-in (Lambda) | Via refreshInterval | N/A | N/A | N/A |

3. **Khi nào dùng gì:**
   - **AWS Secrets Manager:** Cần store credential (DB password, API key) encrypted, có audit log, có rotation
   - **ESO:** Khi dùng GitOps (ArgoCD/Flux), không muốn commit secret vào Git
   - **Trivy:** Scan image trước khi deploy, CI/CD quality gate
   - **Cosign:** Sign artifact (image, SBOM), đảm bảo artifact provenance
   - **Kyverno verifyImages:** Enforce "chỉ deploy image đã sign" ở runtime

### Quyết định architecture

```
Khi build pipeline:
  Trivy (scan) → Cosign (sign) → Push image + signature

Khi deploy:
  Kyverno (verifyImages) → check signature → Allow/Deny

Khi runtime cần secret:
  AWS Secrets Manager (store) → ESO (sync) → K8s Secret (consume)
```

---

## Thứ tự học tổng hợp

```
Section 1 (AWS SM + ESO overview)    [45 phút]
       ↓
Section 2 (AWS SM + IAM + ESO lab)   [45 phút]
       ↓
Section 3 (Trivy image scan CI)      [45 phút]
       ↓
Section 4 (Cosign keyless + key)     [60 phút]
       ↓
Section 5 (Kyverno verifyImages)     [45 phút]
       ↓
Section 6 (CVE exception + SLSA)     [30 phút]
       ↓
Section 7 (Tổng kết)                 [15 phút]
```

**Tổng: ~3.5 giờ** — có thể chia làm 2 buổi:
- Buổi 1: Section 1 → 4 (~2.5 giờ)
- Buổi 2: Section 5 → 7 (~1.5 giờ)

---

## Prerequisites checklist trước khi bắt đầu

- [ ] K8s cluster đang chạy (kind/minikube/EKS)
- [ ] `kubectl` config đúng context
- [ ] AWS CLI installed + configured (`aws configure`)
- [ ] AWS account có permission tạo Secrets Manager + IAM
- [ ] Docker đang chạy
- [ ] `cosign` binary installed
- [ ] `trivy` binary installed
- [ ] Helm installed (để install ESO + Kyverno)
- [ ] GitHub account (cho CI labs)

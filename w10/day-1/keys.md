# Day-1 Keys — RBAC + Admission Policy

Tổng hợp những điểm then chốt cần nhớ sau mỗi section. Dùng để ôn tập nhanh.

---

## Section 1 — RBAC Keys

### 4 Resource chính

| Resource | Scope | Bind được với |
|---|---|---|
| `Role` | Namespace | `RoleBinding` |
| `ClusterRole` | Cluster-wide | `ClusterRoleBinding` |
| `RoleBinding` | Namespace | gắn Role vào subjects |
| `ClusterRoleBinding` | Cluster-wide | gắn ClusterRole vào subjects |

### Subjects (3 loại)
- **`User`** — human users, managed by external auth (OIDC, certificates)
- **`Group`** — một tập users, dùng để set quyền chung
- **`ServiceAccount`** — identity cho Pods/process trong cluster

> SA không gắn → Pod dùng identity mặc định: `default` SA trong namespace của nó.

### kubectl auth can-i
```bash
# Check quyền hiện tại
kubectl auth can-i get pods

# Check quyền của một SA khác
kubectl auth can-i get pods --as=system:serviceaccount:dev:app-reader

# Check quyền của một user
kubectl auth can-i delete pods --as=jenkins-user
```
> Nếu muốn `can-i` check ClusterRole: dùng `--namespace=false`

### Lưu ý quan trọng
- Role/RoleBinding sống trong **cùng namespace**
- ClusterRoleBinding không có namespace → áp dụng toàn cluster
- `kubectl describe rolebinding <name>` để xem subjects + role được bind
- RBAC mặc định **deny-all** — phải explicit grant quyền

---

## Section 2 — RBAC Hands-on Keys

### Quy trình tạo RBAC cho một Pod
```
1. Tạo ServiceAccount (SA)
2. Tạo Role (quyền cụ thể)
3. Tạo RoleBinding (liên kết SA ↔ Role)
4. Gắn SA vào Pod via serviceAccountName
5. Verify bằng kubectl auth can-i
```

### ClusterRole reuse pattern
Một ClusterRole có thể được bind bởi nhiều RoleBinding ở nhiều namespace khác nhau → tiết kiệm, dễ quản lý.

### Các verb thường dùng trong rules
`get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`

### Common mistake
Tạo RoleBinding nhưng SA trong Pod không match → `can-i` vẫn return `no` vì RBAC check trước khi Pod được tạo.

---

## Section 3 — OPA Rego + Gatekeeper Keys

### Rego cấu trúc cơ bản

```rego
package play

default allow = false                           # 1. default deny

allow {
    input.user == "admin"                       # 2. rule body
}

violation[{"msg": msg}] {                        # 3. violation convention
    not allow
    msg := "Access denied"                        # 4. msg khi vi phạm
}
```

### 4 thành phần cốt lõi của Rego
1. **`package`** — namespace cho policy
2. **`default allow = false`** — deny-by-default principle
3. **`input`** — object được evaluate (trong Gatekeeper: admission request)
4. **`violation[...]`** — convention để Gatekeeper hiểu rule thất bại

### Gatekeeper ConstraintTemplate vs Constraint

```
ConstraintTemplate (CT)                    Constraint (C)
    ├── metadata.name                       ├── metadata.name
    ├── spec.crd.spec.names.kind            ├── spec.constraintRef.name  → CT.name
    ├── spec.crd.spec.names.listKind         ├── spec.match (namespace/name filter)
    └── spec.target (OPA Rego code)          └── spec.enforcementAction: deny|dryrun|warn
```

- **CT** = định nghĩa schema + code (template)
- **C** = instance của CT, apply vào resource cụ thể

### Enforcement Actions

| Action | Mode | Khi vi phạm |
|---|---|---|
| `deny` | Enforce | Block request → 403 Forbidden |
| `dryrun` | Audit | Ghi vào violation status, không block |
| `warn` | Warning | Trả về warning, không block |

### Audit mode (dryrun)
```bash
# Xem violations mà không block
kubectl get constraint  # hoặc
kubectl get <constraint-kind>

# Gatekeeper audit pod
kubectl logs -n gatekeeper-system -l control-plane=controller-manager
```

---

## Section 4 — ValidatingAdmissionPolicy Keys

### Kiến trúc VAP

```
ValidatingAdmissionPolicy (VAP)           ValidatingAdmissionPolicyBinding
    ├── spec.matchConstraints               ├── spec.policyName  → VAP.name
    ├── spec.validations (CEL expressions)  └── spec.paramRef    (optional)
    └── spec.paramPolicy.auditAction        └── spec.matchResources
```

### CEL cơ bản

```yaml
validations:
  - expression: "object.metadata.name != 'default'"
    message: "Name cannot be default"
  - expression: "object.spec.replicas <= 10"
    message: "Replicas must be <= 10"
```

### So sánh với Gatekeeper

| | Gatekeeper | ValidatingAdmissionPolicy |
|---|---|---|
| Policy engine | OPA (Rego) | CEL runtime |
| Cần cài đặt | Yes (Gatekeeper addon) | No (native K8s 1.30+) |
| Ngôn ngữ | Rego | CEL expressions |
| Audit | dryrun | auditAnnotation |
| Enforce | deny | enforce |

### MatchResources filter
```yaml
matchConstraints:
  resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
```

### Điều kiện tiên quyết
- Kubernetes 1.30+
- Feature gate `ValidatingAdmissionPolicy=true` (thường enabled by default trong 1.30+)

---

## Section 5 — Tổng kết So sánh

### Khi nào dùng gì

```
Dùng RBAC khi:          Phân quyền ai được làm gì trên K8s resources
Dùng Gatekeeper khi:    Policy phức tạp, cần OPA Rego, external data
Dùng VAP khi:           Policy đơn giản, không muốn cài addon
Dùng Kyverno khi:       Team thích YAML-only, không muốn học Rego/CEL
```

### Check-list sau khi học xong Day-1

- [ ] Tạo được SA + Role + RoleBinding cho một ứng dụng
- [ ] Dùng `kubectl auth can-i` verify được quyền
- [ ] Đọc được một Rego policy và hiểu `input`, `allow`, `violation`
- [ ] Phân biệt được ConstraintTemplate và Constraint
- [ ] Chuyển được Constraint từ audit → enforce mode
- [ ] Viết được một ValidatingAdmissionPolicy đơn giản bằng CEL
- [ ] So sánh được Gatekeeper vs VAP vs Kyverno

---

## Quick Reference Commands

```bash
# RBAC
kubectl auth can-i get pods --as=system:serviceaccount:dev:reader
kubectl get role,rolebinding -n <ns>
kubectl auth reconcile -f rbac.yaml  # reconcile RBAC changes

# Gatekeeper
kubectl get constraint
kubectl get constrainttemplate
kubectl logs -n gatekeeper-system -l control-plane=controller-manager

# VAP (1.30+)
kubectl get validatingadmissionpolicy
kubectl get validatingadmissionpolicybinding
kubectl label ns <ns> admission-policy.kubernetes.io/enforce-policy=<policy-name>
```

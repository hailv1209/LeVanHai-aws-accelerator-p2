# Day-1 Study Plan: RBAC + Admission Policy (OPA/Gatekeeper)

**Thời lượng ước tính:** 3–4 giờ (tự học)  
**Điều kiện tiên quyết:** Kubernetes cơ bản (`kubectl`, namespace, pod)

---

## Chuẩn bị môi trường

Trước khi bắt đầu, đảm bảo bạn có:

- Một Kubernetes cluster (kind, minikube, hoặc EKS/GKE)
- `kubectl` đã cấu hình context
- Gatekeeper đã install (nếu chưa: `kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/master/release/gatekeeper.yaml`)
- Namespace test để labs: `kubectl create ns rbac-lab`

---

## Section 1 — RBAC Cơ bản (45 phút)

### Mục tiêu
Hiểu và phân biệt được 4 resource chính: `Role`, `RoleBinding`, `ClusterRole`, `ClusterRoleBinding`. Hiểu `ServiceAccount` là gì và `kubectl auth can-i` dùng để làm gì.

### Thứ tự học

1. **Đọc tài liệu chính:** [Kubernetes RBAC Docs](https://kubernetes.io/docs/reference/access-authn-authz/rbac)
   - Focus phần "Role and RoleBinding" và "ClusterRole and ClusterRoleBinding"
   - Đọc phần "Subjects" — 3 loại: User, Group, ServiceAccount

2. **Ghi nhớ** (dùng `keys.md` để tra cứu nhanh):
   - `Role` → scope **namespace**
   - `ClusterRole` → scope **toàn cluster**
   - `RoleBinding` → liên kết subjects với Role (namespace-scoped)
   - `ClusterRoleBinding` → liên kết subjects với ClusterRole (cluster-wide)
   - Subjects: `User`, `Group`, `ServiceAccount` (3 loại)
   - SA gắn vào Pod để Pod có identity trong cluster

3. **Xem ví dụ YAML** trong tài liệu trên, tự phân tích xem resource nào nên dùng trong từng scenario.

### Check-point — tự hỏi mình trước khi qua Section 2

- [ ] Role khác ClusterRole ở điểm gì? (scope)
- [ ] RoleBinding khác ClusterRoleBinding ở điểm gì?
- [ ] Tạo sao cần ServiceAccount? Pod không có SA thì sao?
- [ ] Một ServiceAccount có thể được bind bằng RoleBinding lẫn ClusterRoleBinding không?

---

## Section 2 — RBAC Thực hành + kubectl auth can-i (30 phút)

### Mục tiêu
Thực hành tạo Role/RoleBinding/ClusterRole/ClusterRoleBinding, gán SA, và dùng `kubectl auth can-i` để verify quyền.

### Thứ tự học

1. **Đọc lại phần ví dụ** trong [K8s RBAC Docs](https://kubernetes.io/docs/reference/access-authn-authz/rbac) — phần "Example"
2. **Thực hành Lab 1 & Lab 2** (xem `lab.md`)

### Check-point

- [ ] Có thể tạo RoleBinding reference đến ClusterRole không? (Có — ràng buộc cross-resource)
- [ ] `kubectl auth can-i get pods --as=system:serviceaccount:default:default` trả về gì?
- [ ] Muốn một SA chỉ đọc pods trong namespace `dev`, cần tạo gì?

---

## Section 3 — OPA Rego + Gatekeeper (60 phút)

### Mục tiêu
Hiểu cách OPA Rego hoạt động (package, default, input, rules), phân biệt ConstraintTemplate vs Constraint trong Gatekeeper, và hiểu audit mode vs enforce mode.

### Thứ tự học

1. **OPA Rego cơ bản:** [OPA Rego Intro](https://www.openpolicyagent.org/docs/latest/#rego)
   - Đọc phần: "Rego as a query language", "Modules", "Built-in functions"
   - Hiểu: `package`, `default allow = false`, `input`, rule body, `violation` convention

2. **Gatekeeper ConstraintTemplate vs Constraint:**
   - [Gatekeeper Docs](https://open-policy-agent.github.io/gatekeeper/) — phần "How It Works"
   - `ConstraintTemplate`: schema định nghĩa resource + rego code bên trong
   - `Constraint`: instance của Template, specify target (namespace, name) + enforcement action

3. **Audit mode vs Enforce mode:**
   - `EnforcementAction: dryrun` → audit mode (chỉ ghi nhận vi phạm, không block)
   - `EnforcementAction: deny` → enforce mode (block request nếu vi phạm)
   - `EnforcementAction: warn` → chỉ trả về warning

4. **Thực hành Lab 3, 4, 5** (xem `lab.md`)

### Check-point

- [ ] ConstraintTemplate chứa rego hay Constraint chứa rego?
- [ ] Muốn chỉ kiểm tra (audit) không block, dùng enforcement action nào?
- [ ] Làm sao để một Constraint chỉ áp dụng cho namespace `prod`?
- [ ] Tr Rego, `input` chứa gì khi Gatekeeper intercept request?

---

## Section 4 — ValidatingAdmissionPolicy Native (K8s 1.30+) (30 phút)

### Mục tiêu
Hiểu cách K8s native Admission Policy thay thế Gatekeeper cho các use-case đơn giản, cấu trúc CRD, và cách dùng CEL expressions.

### Thứ tự học

1. **Đọc tài liệu:** [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
   - Cấu trúc: `ValidatingAdmissionPolicy` + `ValidatingAdmissionPolicyBinding`
   - Dùng **CEL** (Common Expression Language) thay vì Rego
   - Phân biệt `audit` vs `enforce` trong `.spec.paramPolicy`

2. **So sánh với Gatekeeper:**
   - VAP dùng CEL → nhẹ hơn, không cần OPA engine riêng
   - Gatekeeper dùng Rego → mạnh mẽ hơn, phức tạp hơn
   - Migration: có thể chuyển dần từ Gatekeeper CT sang VAP

3. **Thực hành Lab 6, 7** (xem `lab.md`)

### Check-point

- [ ] VAP dùng ngôn ngữ policy nào? Khác gì Rego?
- [ ] ValidatingAdmissionPolicyBinding dùng để làm gì?
- [ ] Khi nào nên dùng VAP thay vì Gatekeeper?
- [ ] Có thể dùng cả VAP và Gatekeeper cùng lúc không?

---

## Section 5 — Tổng kết + So sánh công cụ (15 phút)

### Mục tiêu
Tổng hợp lại toàn bộ kiến thức, hiểu khi nào dùng tool nào.

### Thứ tự học

1. **Đọc `keys.md`** — ôn lại toàn bộ keys của 4 section trước
2. **Xem bảng so sánh** dưới đây
3. **Thực hành Lab 8** — so sánh Gatekeeper vs VAP cùng một policy

### Bảng so sánh công cụ Admission

| Tiêu chí | Gatekeeper | ValidatingAdmissionPolicy | Kyverno |
|---|---|---|---|
| Policy engine | OPA Rego | CEL | JSONPatch + match |
| Cài đặt | Helm / YAML (addon) | Native (không cần addon) | Helm / YAML |
| Policy language | Rego | CEL (biểu thức) | YAML (policy as CRD) |
| Audit mode | `dryrun` | `audit` | `audit` |
| Enforce mode | `deny` | `enforce` | `enforce` |
| Complexity | Cao (Rego) | Thấp–Trung bình (CEL) | Thấp (YAML only) |
| Use case tốt nhất | Policy phức tạp, cross-resource | Policy đơn giản, native | Policy đơn giản, dễ viết |
| Migration từ Gatekeeper | — | Có thể, nhưng phức tạp | Kyverno policies tương đương |

### Quyết định chọn tool

- **Policy đơn giản** (label, image tag): dùng **VAP native** (không cần cài thêm)
- **Policy phức tạp** (cross-namespace, external data): dùng **Gatekeeper**
- **Team không quen Rego/CEL**: dùng **Kyverno**
- **Multi-cluster, cần centralized policy**: **OPA Bundle + Gatekeeper**

---

## Thứ tự học tổng hợp

```
Section 1 (lý thuyết RBAC)      [45 phút]
       ↓
Section 2 (lab RBAC)            [30 phút]
       ↓
Section 3 (OPA Rego + Gatekeeper) [60 phút]
       ↓
Section 4 (VAP native 1.30+)    [30 phút]
       ↓
Section 5 (tổng kết)            [15 phút]
```

**Tổng: ~3 giờ** — có thể chia làm 2 buổi học nếu cần.

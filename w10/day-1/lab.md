# Day-1 Labs — RBAC + Admission Policy

**Namespace dùng chung cho tất cả labs:** `rbac-lab`  
**Tạo namespace trước:**
```bash
kubectl create ns rbac-lab
```

> Nếu cluster không có Gatekeeper, install trước:
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/master/release/gatekeeper.yaml
> ```

---

## Lab 1 — RBAC Cơ bản: SA + Role + RoleBinding + auth can-i

**Mục tiêu:** Tạo một ServiceAccount `app-reader` chỉ có quyền `get` và `list` trên Pods trong namespace `rbac-lab`.

**Điều kiện tiên quyết:** Namespace `rbac-lab` đã tạo, kubectl context trỏ đúng cluster.

### Các bước thực hiện

**Step 1 — Tạo ServiceAccount**
```bash
kubectl create sa app-reader -n rbac-lab
```

**Step 2 — Tạo Role**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: rbac-lab
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF
```

**Step 3 — Tạo RoleBinding gắn SA vào Role**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: rbac-lab
subjects:
- kind: ServiceAccount
  name: app-reader
  namespace: rbac-lab
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

**Step 4 — Verify quyền bằng kubectl auth can-i**
```bash
# Quyền được phép
kubectl auth can-i get pods --as=system:serviceaccount:rbac-lab:app-reader -n rbac-lab
kubectl auth can-i list pods --as=system:serviceaccount:rbac-lab:app-reader -n rbac-lab

# Quyền bị từ chối
kubectl auth can-i delete pods --as=system:serviceaccount:rbac-lab:app-reader -n rbac-lab
kubectl auth can-i create pods --as=system:serviceaccount:rbac-lab:app-reader -n rbac-lab
```

### Cách verify kết quả

| Lệnh | Kết quả mong đợi |
|---|---|
| `get pods` (can-i) | `yes` |
| `list pods` (can-i) | `yes` |
| `delete pods` (can-i) | `no` |
| `create pods` (can-i) | `no` |

**Kết quả mong đợi:** SA `app-reader` chỉ đọc được Pods, không tạo/sửa/xóa được.

---

## Lab 2 — ClusterRole + ClusterRoleBinding: node-reader cluster-wide

**Mục tiêu:** Tạo ClusterRole cho phép đọc Nodes ở mọi namespace, bind cho SA `devops` (cluster-wide).

**Điều kiện tiên quyết:** Cluster có Nodes đang chạy.

### Các bước thực hiện

**Step 1 — Tạo SA trong namespace devops-ns**
```bash
kubectl create ns devops-ns
kubectl create sa devops -n devops-ns
```

**Step 2 — Tạo ClusterRole đọc Nodes**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-reader
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
EOF
```

**Step 3 — Tạo ClusterRoleBinding (cluster-wide, không namespace)**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: devops-node-reader
subjects:
- kind: ServiceAccount
  name: devops
  namespace: devops-ns
roleRef:
  kind: ClusterRole
  name: node-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

**Step 4 — Verify từ namespace khác (rbac-lab)**
```bash
kubectl auth can-i get nodes --as=system:serviceaccount:devops-ns:devops -n rbac-lab
kubectl auth can-i get nodes --as=system:serviceaccount:devops-ns:devops -n kube-system
```

**Bonus:** So sánh với Lab 1 — ClusterRoleBinding có namespace không? (Đáp: Không)

### Cách verify kết quả

| Lệnh | Kết quả mong đợi |
|---|---|
| `get nodes` từ bất kỳ namespace nào | `yes` |
| `delete nodes` | `no` |
| Xem ClusterRoleBinding: `kubectl get clusterrolebinding devops-node-reader` | Hiển thị subject + role |

---

## Lab 3 — Gatekeeper: ConstraintTemplate + Constraint (chặn image `:latest`)

**Mục tiêu:** Tạo Gatekeeper policy không cho phép container image kết thúc bằng `:latest`.

**Điều kiện tiên quyết:** Gatekeeper đã install trong cluster.

### Các bước thực hiện

**Step 1 — Tạo ConstraintTemplate**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: constraints.gatekeeper.sh/v1
kind: K8sRequiredLabels
metadata:
  name: no-latest-tag  # Lưu ý: kind phải khớp với CRD spec.names.kind
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    labels:
      - key: "image"
        allowedRegex: ".+:[^latest]+$"
EOF
```

> **Lưu ý:** Template trên dùng `K8sRequiredLabels` — template có sẵn trong Gatekeeper library. Nếu muốn tự viết template mới, xem cấu trúc full tại Gatekeeper repo.

**Step 2 — Tạo Constraint thực tế (dùng template K8sBlockLatestTag có sẵn)**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: constraints.gatekeeper.sh/v1
kind: K8sBlockLatestTag
metadata:
  name: no-latest-tag-pods
spec:
  enforcementAction: dryrun   # Bắt đầu với dryrun (audit mode)
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
EOF
```

**Step 3 — Tạo một Pod vi phạm để test**
```bash
cat <<EOF | kubectl apply -f - --dry-run=server
apiVersion: v1
kind: Pod
metadata:
  name: test-latest-image
  namespace: rbac-lab
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Step 4 — Xem violations**
```bash
kubectl get no-latest-tag-pods -o yaml
# Tìm phần .status.violations
```

### Cách verify kết quả

| Hành động | Kết quả mong đợi |
|---|---|
| Tạo Pod `nginx:latest` | **Bị chặn** (nếu enforce) hoặc ghi violation (nếu dryrun) |
| `kubectl get constraint` | Hiển thị `no-latest-tag-pods` |
| Xem violation status | Pod vi phạm được liệt kê trong `.status.violations` |

---

## Lab 4 — Gatekeeper Audit Mode: xem violation report

**Mục tiêu:** Chuyển Constraint sang audit mode, xem toàn bộ violations trong cluster mà không block.

**Điều kiện tiên quyết:** Hoàn thành Lab 3.

### Các bước thực hiện

**Step 1 — Verify Constraint đang ở dryrun**
```bash
kubectl get K8sBlockLatestTag no-latest-tag-pods -o jsonpath='{.spec.enforcementAction}'
# Mong đợi: dryrun
```

**Step 2 — Xem violation count**
```bash
kubectl get K8sBlockLatestTag no-latest-tag-pods
```

**Step 3 — Xem chi tiết violations**
```bash
kubectl get K8sBlockLatestTag no-latest-tag-pods -o jsonpath='{.status.violations}' | jq .
```

**Step 4 — Kiểm tra Gatekeeper audit logs**
```bash
kubectl logs -n gatekeeper-system -l control-plane=controller-manager --tail=50 | grep -i violation
```

**Step 5 — Tạo thêm Pod vi phạm trong namespace khác**
```bash
kubectl run bad-pod --image=redis:latest -n default --dry-run=server -o yaml | kubectl apply -f -
kubectl get K8sBlockLatestTag no-latest-tag-pods -o jsonpath='{.status.violations}' | jq 'length'
# Số violations tăng lên
```

### Cách verify kết quả

| Kiểm tra | Kết quả mong đợi |
|---|---|
| Pod `nginx:latest` vẫn tạo được không? | **Có** (dryrun không block) |
| Violations được ghi nhận? | **Có** (trong `.status.violations`) |
| Gatekeeper logs có ghi audit? | **Có** |

---

## Lab 5 — Gatekeeper Enforce Mode: chặn thật sự

**Mục tiêu:** Chuyển Constraint sang enforce mode (deny), Pod vi phạm sẽ bị từ chối.

### Các bước thực hiện

**Step 1 — Sửa enforcementAction từ dryrun → deny**
```bash
kubectl patch K8sBlockLatestTag no-latest-tag-pods \
  --type=merge \
  -p '{"spec":{"enforcementAction":"deny"}}'
```

**Step 2 — Verify đã đổi**
```bash
kubectl get K8sBlockLatestTag no-latest-tag-pods -o jsonpath='{.spec.enforcementAction}'
# Mong đợi: deny
```

**Step 3 — Thử tạo Pod vi phạm**
```bash
# Sẽ bị từ chối — không tạo được
kubectl run test-deny --image=nginx:latest -n rbac-lab
```

**Step 4 — Xem lỗi từ admission webhook**
```bash
kubectl run test-deny --image=nginx:latest -n rbac-lab 2>&1
# Mong đợi: Error from server ... admission webhook ... denied the request
```

**Step 5 — Verify Pod hợp lệ vẫn tạo được**
```bash
# Image có tag cụ thể — không bị chặn
kubectl run good-pod --image=nginx:1.27 -n rbac-lab
kubectl get pods -n rbac-lab
```

### Cách verify kết quả

| Hành động | Kết quả mong đợi |
|---|---|
| Tạo Pod `nginx:latest` | **Bị từ chối** (403 Forbidden) |
| Tạo Pod `nginx:1.27` | **Thành công** |
| Violation count trong status | Không còn tăng (vì bị deny rồi) |

---

## Lab 6 — ValidatingAdmissionPolicy: chặn label `env=prod` thiếu

**Mục tiêu:** Viết một VAP bằng CEL yêu cầu tất cả Pods phải có label `env`.

**Điều kiện tiên quyết:** Kubernetes 1.30+, feature gate `ValidatingAdmissionPolicy` enabled.

### Các bước thực hiện

**Step 1 — Kiểm tra version K8s**
```bash
kubectl version --short
# Mong đợi: Server Version: v1.30+
```

**Step 2 — Tạo ValidatingAdmissionPolicy**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-env-label
spec:
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
  validations:
  - expression: "object.metadata.labels.exists(k, k == 'env')"
    message: "All pods must have a label 'env'"
EOF
```

**Step 3 — Tạo ValidatingAdmissionPolicyBinding**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-env-label-binding
spec:
  policyName: require-env-label
  validationActions: [Audit, Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["rbac-lab"]
EOF
```

**Step 4 — Bật policy (bind vào namespace)**
```bash
# VAP cần được "activate" bằng binding
kubectl label ns rbac-lab admission-policy.kubernetes.io/enforce-policy=require-env-label
```

**Step 5 — Test: tạo Pod không có label env**
```bash
cat <<EOF | kubectl apply -f - --namespace=rbac-lab
apiVersion: v1
kind: Pod
metadata:
  name: no-env-label
  namespace: rbac-lab
spec:
  containers:
  - name: test
    image: nginx:1.27
EOF
# Mong đợi: denied
```

**Step 6 — Test: Pod có label env**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: has-env-label
  namespace: rbac-lab
  labels:
    env: prod
spec:
  containers:
  - name: test
    image: nginx:1.27
EOF
# Mong đợi: thành công
```

### Cách verify kết quả

| Hành động | Kết quả mong đợi |
|---|---|
| Pod không có label `env` | **Bị từ chối** với message "All pods must have a label 'env'" |
| Pod có label `env: prod` | **Thành công** |
| `kubectl get validatingadmissionpolicy` | Hiển thị `require-env-label` |

---

## Lab 7 — VAP Audit Mode: xem violation events

**Mục tiêu:** Dùng audit mode của VAP (thay vì deny) để ghi nhận violations mà không block.

### Các bước thực hiện

**Step 1 — Sửa validationActions chỉ để Audit**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-env-label-binding
spec:
  policyName: require-env-label
  validationActions: [Audit]   # Chỉ audit, không Deny
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["rbac-lab"]
EOF
```

**Step 2 — Tạo Pod vi phạm (sẽ được tạo thành công vì chỉ audit)**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: no-env-audit
  namespace: rbac-lab
spec:
  containers:
  - name: test
    image: nginx:1.27
EOF
# Thành công (vì audit không block)
```

**Step 3 — Xem audit results**
```bash
# Xem annotation trên namespace hoặc pod
kubectl get pod no-env-audit -n rbac-lab -o yaml | grep -A5 audit
```

**Step 4 — Xem admission policy audit results**
```bash
kubectl get ValidatingAdmissionPolicyEvaluation
# Hoặc xem events trong namespace
kubectl get events -n rbac-lab --field-selector=reason=PolicyViolation
```

### Cách verify kết quả

| Hành động | Kết quả mong đợi |
|---|---|
| Pod không có label `env` tạo được không? | **Có** (audit không block) |
| Violation được ghi nhận? | **Có** (event/annotation) |
| Pod có label vẫn tạo bình thường? | **Có** |

---

## Lab 8 — So sánh: cùng policy bằng Gatekeeper vs VAP

**Mục tiêu:** Tạo cùng một policy rule (không cho phép tạo Deployment với `privileged: true` SecurityContext) bằng cả Gatekeeper và VAP, so sánh sự khác biệt.

### Gatekeeper approach

**Step 1 — Tạo ConstraintTemplate (Gatekeeper)**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8snoprivileged
spec:
  crd:
    spec:
      names:
        kind: K8sNoPrivileged
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package no_privileged
      violation[{"msg": msg}] {
        containers := input.review.object.spec.template.spec.containers
        containers[_].securityContext.privileged == true
        msg := "Containers cannot run as privileged"
      }
EOF
```

**Step 2 — Tạo Constraint**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: constraints.gatekeeper.sh/v1
kind: K8sNoPrivileged
metadata:
  name: no-privileged-deployments
spec:
  enforcementAction: deny
  match:
    kinds:
    - apiGroups: ["apps"]
      kinds: ["Deployment"]
EOF
```

### VAP approach (CEL)

**Step 3 — Tạo ValidatingAdmissionPolicy**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingAdmissionPolicy
metadata:
  name: no-privileged-deployment
spec:
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments"]
  validations:
  - expression: |
      !object.spec.template.spec.containers.exists(c, c.securityContext.privileged == true)
    message: "Containers cannot run as privileged"
EOF
```

**Step 4 — Tạo Binding cho VAP**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: no-privileged-deployment-binding
spec:
  policyName: no-privileged-deployment
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["rbac-lab"]
EOF
```

**Step 5 — Test cả hai**
```bash
# Tạo Deployment privileged (test Gatekeeper)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: privileged-deploy
  namespace: rbac-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        securityContext:
          privileged: true
EOF

# Gatekeeper: bị deny (nếu Deployment được intercept)
# VAP: bị deny
```

**Step 6 — Ghi lại diff**

Tạo file `diff-comparison.md` trong thư mục lab để ghi lại:

| Tiêu chí | Gatekeeper | VAP |
|---|---|---|
| Ngôn ngữ policy | Rego | CEL |
| Số dòng code | ~15 | ~5 |
| Cần ConstraintTemplate? | Có | Không |
| Cần Binding riêng? | Không (CT/Constraint đã đủ) | Có (VAP + Binding) |
| Mức độ đọc hiểu | Khó hơn (Rego) | Dễ hơn (CEL gần biểu thức logic) |
| Phù hợp cho policy phức tạp? | Rất phù hợp | Hạn chế |

### Cách verify kết quả

- [ ] Gatekeeper `K8sNoPrivileged` constraint tồn tại và `deny`
- [ ] VAP `no-privileged-deployment` policy + binding tồn tại
- [ ] Deployment `privileged: true` bị cả hai chặn
- [ ] File `diff-comparison.md` được tạo với ít nhất 4 tiêu chí so sánh

---

## Bonus — Cleanup

Sau khi hoàn thành tất cả labs, dọn dẹp resources:

```bash
# RBAC
kubectl delete ns rbac-lab devops-ns

# Gatekeeper constraints
kubectl delete K8sBlockLatestTag no-latest-tag-pods
kubectl delete K8sNoPrivileged no-privileged-deployments

# VAP
kubectl delete ValidatingAdmissionPolicy require-env-label no-privileged-deployment
kubectl delete ValidatingAdmissionPolicyBinding require-env-label-binding no-privileged-deployment-binding
```

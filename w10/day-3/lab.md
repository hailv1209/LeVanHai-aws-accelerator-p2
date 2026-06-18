# Day-3 Labs — Platform Integration + Runbook + Cost Guard

10 labs theo thứ tự, mỗi lab có: Mục tiêu, Điều kiện tiên quyết, Các bước thực hiện, Cách verify kết quả.

---

## Tổng quan Labs

| Lab | Chủ đề | Độ khó |
|-----|--------|--------|
| Lab 1 | LimitRange: default CPU/memory injection | Dễ |
| Lab 2 | ResourceQuota: hard limit namespace quota | Dễ |
| Lab 3 | Test: pod auto-inject default (không specify) | Dễ |
| Lab 4 | Test: pod bị reject vượt ResourceQuota | Trung bình |
| Lab 5 | Fix: điều chỉnh resources pass quota | Trung bình |
| Lab 6 | Install Litmus + verify pods | Dễ |
| Lab 7 | ChaosExperiment: pod-delete | Trung bình |
| Lab 8 | Network latency chaos + observe | Trung bình |
| Lab 9 | Viết runbook cho incident | Trung bình |
| Lab 10 | Tabletop exercise: chaos drill | Cao |

---

## Lab 1 — LimitRange: default CPU/memory injection

**Mục tiêu:** Tạo LimitRange inject default `requests` và `limits` cho containers không specify resources.

**Điều kiện tiên quyết:** K8s cluster đang chạy, `kubectl` config đúng context.

### Các bước thực hiện

**Step 1:** Tạo namespace mới.

```bash
kubectl create ns limitrange-demo
```

**Step 2:** Tạo LimitRange YAML với default CPU/memory.

```yaml
# limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: limitrange-demo
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 256Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "2"
      memory: 2Gi
    min:
      cpu: 10m
      memory: 32Mi
```

```bash
kubectl apply -f limitrange.yaml
```

**Step 3:** Verify LimitRange đã được tạo.

```bash
kubectl get limitrange -n limitrange-demo
kubectl describe limitrange default-limits -n limitrange-demo
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| LimitRange tồn tại | `kubectl get limitrange` hiển thị `default-limits` |
| Type là `Container` | `describe` hiển thị `Type: Container` |
| Có `default` + `defaultRequest` | `describe` hiển thị cả hai sections |

---

## Lab 2 — ResourceQuota: hard limit namespace quota

**Mục tiêu:** Tạo ResourceQuota giới hạn tổng CPU/memory + số lượng pods trong namespace.

**Điều kiện tiên quyết:** Hoàn thành Lab 1 (namespace `limitrange-demo` đã tồn tại).

### Các bước thực hiện

**Step 1:** Tạo ResourceQuota YAML.

```yaml
# resourcequota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: limitrange-demo
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "5"
    services: "3"
    secrets: "5"
    configmaps: "5"
```

```bash
kubectl apply -f resourcequota.yaml
```

**Step 2:** Verify ResourceQuota đã được tạo.

```bash
kubectl get resourcequota -n limitrange-demo
kubectl describe resourcequota team-quota -n limitrange-demo
```

**Step 3:** Xác minh `hard` limits đúng giá trị đã set.

```bash
kubectl describe resourcequota team-quota -n limitrange-demo | grep -A 20 "Hard"
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| ResourceQuota tồn tại | `kubectl get resourcequota` hiển thị `team-quota` |
| Hard limits đúng | `requests.cpu: 2`, `requests.memory: 2Gi` |
| Used = 0 ban đầu | `used` section hiển thị toàn 0 |
| Status = Green | `Status: Green` (chưa sử dụng gì) |

---

## Lab 3 — Test pod auto-inject default (không specify)

**Mục tiêu:** Tạo pod không có `requests/limits` → xem LimitRange auto-fill giá trị mặc định.

**Điều kiện tiên quyết:** LimitRange + ResourceQuota đã tạo (Lab 1 + Lab 2).

### Các bước thực hiện

**Step 1:** Tạo pod YAML KHÔNG có section `resources`.

```yaml
# pod-no-resources.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-auto-inject
  namespace: limitrange-demo
spec:
  containers:
  - name: app
    image: nginx:alpine
```

```bash
kubectl apply -f pod-no-resources.yaml
```

**Step 2:** Chờ pod running.

```bash
kubectl wait pod test-auto-inject -n limitrange-demo --for=condition=Ready --timeout=30s
```

**Step 3:** Kiểm tra resources đã được auto-inject.

```bash
kubectl get pod test-auto-inject -n limitrange-demo -o jsonpath='{.spec.containers[*].resources}'
```

**Step 4:** Xem ResourceQuota usage đã tăng.

```bash
kubectl describe resourcequota team-quota -n limitrange-demo
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| Pod running | `kubectl get pod` hiển thị `Running` |
| Auto-inject requests | `requests.cpu: 100m`, `requests.memory: 128Mi` |
| Auto-inject limits | `limits.cpu: 500m`, `limits.memory: 256Mi` |
| ResourceQuota used tăng | `used.requests.cpu: 100m` (1 pod × default) |

---

## Lab 4 — Test pod bị reject vượt ResourceQuota

**Mục tiêu:** Tạo pod với requests/limits vượt ResourceQuota hard limit → bị reject.

**Điều kiện tiên quyết:** Hoàn thành Lab 3 (ResourceQuota đang có 1 pod dùng 100m CPU).

### Các bước thực hiện

**Step 1:** Tạo pod YAML với resources vượt quota.

```yaml
# pod-over-quota.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-over-quota
  namespace: limitrange-demo
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: "3"
        memory: 1Gi
      limits:
        cpu: "4"
        memory: 2Gi
```

```bash
kubectl apply -f pod-over-quota.yaml
```

**Step 2:** Chờ 5 giây rồi kiểm tra pod status.

```bash
sleep 5
kubectl get pod test-over-quota -n limitrange-demo
```

**Step 3:** Xem events để tìm lỗi.

```bash
kubectl describe pod test-over-quota -n limitrange-demo | grep -A 10 "Events"
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| Pod bị reject | `kubectl get pod` hiển thị `Failed` hoặc `Pending` |
| Lỗi quota | Events có `"exceeded quota"` hoặc `"Fails for quota"` |
| ResourceQuota used chưa đổi | `used` values không thay đổi (pod chưa được count) |

---

## Lab 5 — Fix pod để pass qua quota

**Mục tiêu:** Điều chỉnh resources của pod để nằm trong ResourceQuota limit.

**Điều kiện tiên quyết:** Hoàn thành Lab 4 (pod `test-over-quota` đang bị reject).

### Các bước thực hiện

**Step 1:** Xác định hard limit còn lại.

```bash
kubectl describe resourcequota team-quota -n limitrange-demo
```

Output sẽ hiển thị:
```
Hard:
  requests.cpu:    2        (used: 100m, remain: 1900m)
  requests.memory: 2Gi      (used: 128Mi, remain: ~1912Mi)
  limits.cpu:      4        (used: 500m, remain: 3500m)
  limits.memory:   4Gi      (used: 256Mi, remain: ~3830Mi)
```

**Step 2:** Xóa pod bị reject cũ.

```bash
kubectl delete pod test-over-quota -n limitrange-demo --ignore-not-found=true
```

**Step 3:** Tạo pod với resources nằm trong quota.

```yaml
# pod-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-fixed
  namespace: limitrange-demo
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: "1"
        memory: 500Mi
      limits:
        cpu: "2"
        memory: 1Gi
```

```bash
kubectl apply -f pod-fixed.yaml
```

**Step 4:** Verify pod running + ResourceQuota usage.

```bash
kubectl wait pod test-fixed -n limitrange-demo --for=condition=Ready --timeout=30s
kubectl describe resourcequota team-quota -n limitrange-demo
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| Pod running | `kubectl get pod test-fixed` hiển thị `Running` |
| requests.cpu ≤ hard limit | `1 ≤ 2` → ✅ |
| requests.memory ≤ hard limit | `500Mi ≤ 2Gi` → ✅ |
| ResourceQuota used tăng | `used.requests.cpu: 1100m` (100m + 1000m) |
| Status = Green | `Status: Green` |

---

## Lab 6 — Install Litmus + verify pods

**Mục tiêu:** Install Litmus Chaos qua Helm, verify các pod đang chạy.

**Điều kiện tiên quyết:** K8s cluster đang chạy, Helm installed.

### Các bước thực hiện

**Step 1:** Thêm Litmus Helm repo.

```bash
helm repo add litmus https://litmuschaos.github.io/litmus-helm/
helm repo update
```

**Step 2:** Tạo namespace cho Litmus.

```bash
kubectl create ns litmus
```

**Step 3:** Install Litmus.

```bash
helm install litmus litmus/litmus -n litmus
```

**Step 4:** Chờ tất cả pods running.

```bash
kubectl wait --for=condition=Ready pod --all -n litmus --timeout=120s
```

**Step 5:** Verify Litmus pods đang chạy.

```bash
kubectl get pods -n litmus
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| Helm release installed | `helm list -n litmus` hiển thị `litmus` |
| Tất cả pods Running | `kubectl get pods -n litmus` — không có `Pending`/`CrashLoop` |
| Có chaos-operator | Tên chứa `chaos-operator` hoặc `litmus` |
| Có chaos-runner | Tên chứa `chaos-runner` (chạy experiments) |

---

## Lab 7 — ChaosExperiment: pod-delete

**Mục tiêu:** Tạo ChaosExperiment xóa pod ngẫu nhiên, chạy experiment, xem kết quả ChaosResult.

**Điều kiện tiên quyết:** Litmus đã installed (Lab 6).

### Các bước thực hiện

**Step 1:** Tạo namespace mục tiêu + deploy test app.

```bash
kubectl create ns chaos-test
kubectl run nginx-pod --image=nginx:alpine -n chaos-test
kubectl wait pod nginx-pod -n chaos-test --for=condition=Ready --timeout=30s
```

**Step 2:** Tạo ChaosExperiment YAML (template).

```yaml
# chaos-experiment-pod-delete.yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosExperiment
metadata:
  name: pod-delete
  namespace: litmus
spec:
  definition:
    image: litmuschaos/chaos-runner:latest
    args:
    - -c
    - |
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: pod-delete
      spec:
        template:
          spec:
            containers:
            - name: chaos
              image: litmuschaos/pod-delete:latest
              env:
              - name: APP_LABEL
                value: "app=nginx"
              - name: APP_NAMESPACE
                value: "chaos-test"
            restartPolicy: Never
```

```bash
kubectl apply -f chaos-experiment-pod-delete.yaml
```

**Step 3:** Tạo ChaosEngine YAML (instance).

```yaml
# chaos-engine.yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: nginx-chaos
  namespace: chaos-test
spec:
  appinfo:
    appns: chaos-test
    applabel: "app=nginx"
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
  - name: pod-delete
    spec:
      components:
        env:
        - name: TOTAL_CHAOS_DURATION
          value: "30"
        - name: CHAOS_INTERVAL
          value: "10"
        - name: FORCE
          value: "True"
```

```bash
kubectl apply -f chaos-engine.yaml
```

**Step 4:** Xem ChaosResult được tạo.

```bash
kubectl get chaosresult -n chaos-test
kubectl describe chaosresult <chaos-result-name> -n chaos-test
```

**Step 5:** Dọn dẹp sau khi lab xong.

```bash
kubectl delete chaosengine nginx-chaos -n chaos-test
kubectl delete chaosexperiment pod-delete -n litmus
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| ChaosEngine tạo được | `kubectl get chaosengine` hiển thị `nginx-chaos` |
| Pod bị delete trong quá trình | `kubectl get pod -n chaos-test` hiển thị pod `Terminating` rồi `Running` (restart) |
| ChaosResult tồn tại | `kubectl get chaosresult` hiển thị result |
| Verdict | `describe chaosresult` hiển thị `Verdict: Pass` hoặc `Fail` |

---

## Lab 8 — Network latency chaos + observe

**Mục tiêu:** Tạo NetworkChaos thêm latency 500ms, deploy test app, quan sát degradation.

**Điều kiện tiên quyết:** Hoàn thành Lab 7 (Litmus đã installed, namespace `chaos-test` đã có).

### Các bước thực hiện

**Step 1:** Deploy test app có endpoint để check latency.

```bash
kubectl create deployment echo-server --image=kennethreitz/httpbin:latest -n chaos-test
kubectl expose deployment echo-server --port=80 --target-port=80 -n chaos-test
kubectl wait pod -l app=echo-server -n chaos-test --for=condition=Ready --timeout=30s
```

**Step 2:** Tạo NetworkChaos YAML.

```yaml
# network-chaos.yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: network-latency
  namespace: chaos-test
spec:
  appinfo:
    appns: chaos-test
    applabel: "app=echo-server"
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
  - name: network-chaos
    spec:
      components:
        env:
        - name: TOTAL_CHAOS_DURATION
          value: "60"
        - name: NETWORK_LATENCY
          value: "500"
        - name: LATENCY_JITTER
          value: "100"
```

```bash
kubectl apply -f network-chaos.yaml
```

**Step 3:** Trong khi chaos đang chạy, observe latency.

```bash
# Port-forward
kubectl port-forward svc/echo-server 8080:80 -n chaos-test &

# Trong terminal khác, gửi request và đo latency
curl -o /dev/null -s -w "Total time: %{time_total}s\n" http://localhost:8080/get
```

**Step 4:** Xem kết quả ChaosResult.

```bash
kubectl get chaosresult -n chaos-test
kubectl describe chaosresult <network-chaos-result> -n chaos-test
```

**Step 5:** Dọn dẹp.

```bash
kubectl delete chaosengine network-latency -n chaos-test
kubectl delete deployment echo-server -n chaos-test
kubectl delete svc echo-server -n chaos-test
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| ChaosEngine chạy | `kubectl get chaosengine` hiển thị `Running` |
| Latency tăng | `curl` time_total ≈ 500ms–1s (thay vì <50ms bình thường) |
| ChaosResult Pass | `describe chaosresult` hiển thị `Verdict: Pass` |
| Pod vẫn running | Pod không bị crash, chỉ có network delay |

---

## Lab 9 — Viết runbook cho incident

**Mục tiêu:** Viết runbook template cho incident "Pod bị kill bởi chaos experiment" theo Google SRE Workbook.

**Điều kiện tiên quyết:** Đã đọc runbook template section trong Section 4 (keys.md).

### Các bước thực hiện

**Step 1:** Tạo file runbook markdown.

```bash
# Tạo file runbook
cat > runbook-pod-kill.md << 'EOF'
# Runbook: Pod bị kill bởi Chaos Experiment

## Description
Pod trong namespace production bị xóa/kill do Litmus ChaosExperiment chạy bình thường.
Đây là expected behavior trong chaos drill — cần xác nhận và rollback nếu cần.

## Symptoms
- Pod trong namespace `production` có status `Terminating` hoặc `CrashLoopBackOff`
- Log hiển thị: "Pod was deleted as part of chaos experiment"
- Kubernetes Events: `Killing` container, `Pulling` image (recreation)
- Application trả lỗi 503 trong thời gian ngắn (< 30s)

## Detection
- Alert source: Litmus ChaosResult (namespace `litmus`)
- Alert name: `ChaosExperimentCompleted`
- ChaosEngine reference: `kubectl get chaosengine -A`
- Manual check: `kubectl get pods -n production`

## Triage
- Severity: P2 (High) — application có downtime ngắn
- Impact scope: 1 namespace (`production`)
- Blast radius: Tất cả users truy cập service trong namespace
- Is this expected? Check chaos schedule: `kubectl get chaosengine -A`

## Mitigation Steps

### Step 1: Xác nhận đây là planned chaos (≤ 2 phút)
```bash
kubectl get chaosengine -A
kubectl get chaosresult -n <chaos-namespace>
```
**Expected output:** ChaosEngine đang `Running`, ChaosResult status `Running`

**Nếu đây là PLANNED chaos → Chờ pod tự recover (HPA/Deployment scale)**
**Nếu KHÔNG PHẢI planned chaos → Chuyển sang Rollback**

### Step 2: Chờ pod tự recover (≤ 5 phút)
```bash
kubectl rollout status deployment/<deployment-name> -n production --timeout=60s
```
**Expected output:** `deployment "<name>" successfully rolled out`

### Step 3: Verify application healthy (≤ 2 phút)
```bash
kubectl get pods -n production
kubectl rollout status deployment/<deployment-name> -n production
curl http://<service-url>/healthz
```
**Expected output:** Tất cả pods `Running`, healthz trả `200 OK`

## Rollback
Nếu pod không tự recover sau 5 phút:

```bash
# Rollback deployment về revision trước
kubectl rollout undo deployment/<deployment-name> -n production

# Xác minh
kubectl rollout status deployment/<deployment-name> -n production
```

## Escalation
- Nếu vượt 10 phút mà chưa fix → Escalate đến SRE lead
- Slack channel: `#sre-oncall`
- Contact: @sre-lead (Slack) / sre-lead@company.com
- PagerDuty: escalation policy `platform-oncall`

## Verification
- [ ] Tất cả pods trong namespace `production` đang `Running`
- [ ] `kubectl rollout status` hoàn thành
- [ ] `/healthz` endpoint trả `200 OK`
- [ ] Error rate về baseline (< 0.1%)
- [ ] Latency P99 về baseline (< 200ms)

## Postmortem Template (Google SRE Workbook)

### Timeline
| Thời gian (UTC) | Sự kiện |
|-----------------|---------|
| T+0m | Alert fired: ChaosExperimentCompleted |
| T+1m | Responder triage: xác nhận planned chaos |
| T+3m | Pod tự recover (Deployment recreate) |
| T+5m | Application healthy, error rate = 0 |

### Root Cause
Pod bị kill do Litmus ChaosExperiment `pod-delete` chạy theo schedule — đây là
expected behavior trong chaos drill. Deployment có HPA nên pod được recreate tự động.

### Impact
- Downtime: ~3 phút (pod recreation time)
- Users affected: Toàn bộ users truy cập service
- Data loss: Không có (stateless application)

### Action Items
- [ ] Thêm PodDisruptionBudget để giảm blast radius
- [ ] Tăng HPA min replicas từ 1 → 2
- [ ] Thêm readiness probe timeout phù hợp với chaos latency

### Lessons Learned
- HPA với min replicas = 1 dễ gây downtime khi pod bị kill
- Cần có readiness probe cho tất cả services
- Chaos drill nên chạy vào giờ thấp điểm (off-peak hours)
EOF
echo "Runbook created: runbook-pod-kill.md"
```

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| File runbook tồn tại | `ls runbook-pod-kill.md` hiển thị file |
| Có 8 sections chính | Title, Description, Symptoms, Detection, Triage, Mitigation, Rollback, Escalation, Verification |
| Mỗi step có command | Section Mitigation có Step 1/2/3 với command blocks |
| Có Rollback section | Có hướng dẫn `kubectl rollout undo` |
| Có Escalation section | Có contact info + Slack channel |

---

## Lab 10 — Tabletop exercise: chaos drill

**Mục tiêu:** Đọc runbook, role-play các role (responder, escalation, communication), đánh giá gaps.

**Điều kiện tiên quyết:** Hoàn thành Lab 9 (runbook đã được viết).

### Các bước thực hiện

**Step 1:** In runbook + phân công roles.

```bash
cat runbook-pod-kill.md
```

Assign roles:
- **Incident Commander (IC):** Điều phối tổng thể, quyết định escalate
- **Technical Responder:** Chạy commands, verify kết quả
- **Communications Lead:** Cập nhật Slack channel, thông báo stakeholders
- **Observer/Grade:** Ghi lại gaps, đánh giá runbook

**Step 2:** Chạy tabletop exercise theo timeline.

```
T=0m  [IC]       Nhận alert → mở runbook
T=1m  [Responder] Chạy kubectl get chaosengine -A → xác định loại chaos
T=2m  [IC]       Quyết định: Planned chaos → chờ recover
T=3m  [Responder] kubectl rollout status → check pod recovery
T=5m  [Responder] kubectl get pods → verify tất cả Running
T=5m  [IC]       Xác nhận incident resolved
T=6m  [Comms]    Đăng Slack: "Incident resolved, ETA full recovery 10m"
```

**Step 3:** Đánh giá runbook + ghi gaps.

```bash
# Tạo file gaps.md để ghi lại lessons learned
cat > tabletop-gaps.md << 'EOF'
# Tabletop Exercise — Lessons Learned

## Exercise Info
- Date: <today>
- Scenario: Pod killed by chaos experiment
- Participants: <list roles + names>
- Duration: ~10 minutes

## What Went Well
- <mục hoạt động tốt>

## What Went Wrong
- <mục không hoạt động>

## Gaps Found
| # | Gap | Severity | Action |
|---|-----|----------|--------|
| 1 | <ví dụ: Rollback step thiếu timeout config> | High | <thêm timeout vào rollback command> |
| 2 | <ví dụ: Escalation contact không đúng> | Medium | <cập nhật contact list> |

## Runbook Updates Needed
- [ ] <ví dụ: Thêm HPA min replicas check vào triage step>
- [ ] <ví dụ: Thêm Slack webhook vào alert config>
EOF
```

**Step 4:** Cập nhật runbook với lessons learned.

- Đọc `tabletop-gaps.md`
- Cập nhật `runbook-pod-kill.md` với các fix
- Commit nếu dùng Git

### Cách verify kết quả

| Check | Expected output |
|-------|----------------|
| Roles được assign | Có ít nhất 3 roles (IC, Responder, Comms) |
| Exercise chạy đúng timeline | Mỗi step có time marker |
| Gaps được ghi | `tabletop-gaps.md` có ít nhất 1 gap |
| Runbook được cập nhật | `runbook-pod-kill.md` có thay đổi sau exercise |

---

## Tổng kết Labs

### Checklist hoàn thành labs

- [ ] **Lab 1** — LimitRange inject default resources thành công
- [ ] **Lab 2** — ResourceQuota hard limit được tạo đúng giá trị
- [ ] **Lab 3** — Pod không specify resources vẫn chạy (auto-inject)
- [ ] **Lab 4** — Pod vượt quota bị reject (Fails for quota)
- [ ] **Lab 5** — Pod fix resources sau khi vượt quota → running
- [ ] **Lab 6** — Litmus pods đều running sau Helm install
- [ ] **Lab 7** — ChaosEngine pod-delete chạy xong → ChaosResult Pass
- [ ] **Lab 8** — Network latency chaos tăng latency quan sát được
- [ ] **Lab 9** — Runbook viết đủ 8 sections theo Google SRE Workbook
- [ ] **Lab 10** — Tabletop exercise chạy xong, gaps được ghi, runbook cập nhật

### Mối liên kết giữa các labs

```
Lab 1: Tạo LimitRange (default inject)
    ↓
Lab 2: Tạo ResourceQuota (hard limit)
    ↓
Lab 3: Test auto-inject (không specify → LimitRange fill)
    ↓
Lab 4: Test vượt quota → REJECTED
    ↓
Lab 5: Fix pod → PASS quota
    ↓
Lab 6: Install Litmus
    ↓
Lab 7: Pod-delete chaos experiment
    ↓
Lab 8: Network latency chaos
    ↓
Lab 9: Viết runbook cho incident từ Lab 7-8
    ↓
Lab 10: Tabletop exercise (role-play + gaps analysis)
```

---

## Tham khảo

- K8s ResourceQuota docs: https://kubernetes.io/docs/concepts/policy/resource-quotas
- K8s LimitRange docs: https://kubernetes.io/docs/concepts/policy/limit-range
- Litmus Chaos: https://litmuschaos.io
- Chaos Mesh: https://chaos-mesh.org
- Google SRE Workbook: https://sre.google/workbook/example-postmortem
- AWS Cost Anomaly Detection: https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html

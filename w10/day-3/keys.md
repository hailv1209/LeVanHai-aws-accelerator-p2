# Day-3 Keys — Platform Integration + Runbook + Cost Guard

Tổng hợp những điểm then chốt cần nhớ sau mỗi section. Dùng để ôn tập nhanh.

---

## Section 1 — Platform Integration W8→W10 Keys

### 5 Layers của Platform Integration

```
┌─────────────────────────────────────────────────────────────────┐
│                    PLATFORM INTEGRATION STACK                   │
│                                                                 │
│  Layer 1 — SECURITY      Kyverno verifyImages (image signature) │
│                          Gatekeeper / VAP (resource policy)     │
│                                                                 │
│  Layer 2 — IDENTITY      RBAC (Role / RoleBinding / SA)         │
│                          → Kiểm soát WHO được deploy            │
│                                                                 │
│  Layer 3 — SECRET        ESO (External Secrets Operator)        │
│                          AWS Secrets Manager                    │
│                          → Kiểm soát HOW lấy credentials        │
│                                                                 │
│  Layer 4 — RESOURCE      ResourceQuota (namespace hard limit)   │
│                          LimitRange (default + range)           │
│                          → Kiểm soát HOW MUCH resource dùng     │
│                                                                 │
│  Layer 5 — COST          AWS Cost Anomaly Detection             │
│                          → Kiểm soát HOW MUCH chi               │
└─────────────────────────────────────────────────────────────────┘
```

### End-to-End Flow

```
Developer push code
    ↓
[CI Pipeline]
  Trivy scan → docker build → Cosign sign
    ↓
[K8s Admission]
  Kyverno verifyImages (image signed?)
  Gatekeeper / VAP (resource policy)
  RBAC (ai được deploy)
    ↓
[Runtime]
  ESO sync secret → K8s Secret → Pod mount
  ResourceQuota (sum resources ≤ hard limit)
  LimitRange (auto-fill default requests/limits)
    ↓
[Cost Guard]
  AWS Cost Anomaly Detection (phát hiện spike)
  → SNS → Alert → Action
```

### Key concepts

| Layer | Vấn đề giải quyết | Tool chính | Kiểm soát |
|---|---|---|---|
| Security | Image + resource compliance | Kyverno + Gatekeeper/VAP | WHAT được deploy |
| Identity | Phân quyền deploy | RBAC | WHO được deploy |
| Secret | Không hardcode credentials | ESO + AWS Secrets Manager | HOW lấy creds |
| Resource | Ngăn over-provision | ResourceQuota + LimitRange | HOW MUCH resource |
| Cost | Phát hiện cost spike | AWS Cost Anomaly Detection | HOW MUCH chi |

### Sự khác biệt chính giữa các admission tools

| Tool | Kiểm soát | Khi nào chạy | Policy language |
|---|---|---|---|
| Kyverno verifyImages | Image signature | Admission webhook | keyless/key attestor |
| Gatekeeper | Resource compliance | Admission webhook | OPA Rego |
| VAP | Resource compliance | Admission webhook (native) | CEL |
| ResourceQuota | Namespace resource limit | Scheduler | YAML spec |
| LimitRange | Container default/range | Admission | YAML spec |

---

## Section 2 — ResourceQuota + LimitRange Keys

### ResourceQuota — Cấu trúc

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:                          # Hard limits (KHÔNG thể vượt)
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "10"
    services: "5"
    secrets: "10"
    configmaps: "10"
  scopes:                        # Optional scope filter
    - NotBestEffort               # Chỉ áp dụng cho pods có requests/limits
```

### ResourceQuota — Các loại quota

| Quota type | Giải thích | Unit |
|---|---|---|
| `requests.cpu` | Tổng CPU requests của tất cả pods | cores (1000m = 1 core) |
| `requests.memory` | Tổng memory requests của tất cả pods | bytes (Gi, Mi) |
| `limits.cpu` | Tổng CPU limits của tất cả pods | cores |
| `limits.memory` | Tổng memory limits của tất cả pods | bytes |
| `pods` | Tổng số pods trong namespace | count |
| `services` | Tổng số services | count |
| `secrets` | Tổng số secrets | count |
| `configmaps` | Tổng số configmaps | count |
| `persistentvolumeclaims` | Tổng số PVCs | count |

### ResourceQuota — Scope selector

```yaml
spec:
  hard:
    requests.cpu: "4"
  scopeSelector:                  # Chỉ áp dụng cho pods match selector
    matchExpressions:
    - operator: NotIn
      scopeName: BestEffort       # BestEffort = KHÔNG có requests/limits
      values: [""]                # NotBestEffort = CÓ requests/limits
```

### LimitRange — Cấu trúc

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: team-a
spec:
  limits:
  - type: Container                # Áp dụng cho từng container
    default:                      # Default LIMIT nếu không specify
      cpu: 500m
      memory: 256Mi
    defaultRequest:               # Default REQUEST nếu không specify
      cpu: 100m
      memory: 128Mi
    max:                          # Maximum cho container
      cpu: "2"
      memory: 2Gi
    min:                          # Minimum request cho container
      cpu: 10m
      memory: 32Mi
    maxRatio:                     # Ratio tối đa limit/request
      memory: 4
```

### LimitRange — 4 loại

| Type | Áp dụng cho | Example use case |
|---|---|---|
| `Container` | Từng container trong pod | Default CPU/memory cho mỗi container |
| `Pod` | Tổng pod (sum tất cả containers) | Giới hạn tổng pod resources |
| `PersistentVolumeClaim` | PVC trong namespace | Giới hạn PVC storage size |
| `PodCluster` | Tất cả namespaces trong cluster | Cluster-wide default |

### LimitRange — Các field quan trọng

| Field | Khi nào dùng | Ví dụ |
|---|---|---|
| `default` | Container không specify `limits` | Auto-fill `limits.cpu: 500m` |
| `defaultRequest` | Container không specify `requests` | Auto-fill `requests.cpu: 100m` |
| `max` | Container exceed → reject | `max.cpu: 2` (không cho >2 cores) |
| `min` | Container under → reject | `min.cpu: 10m` (phải >= 10m) |
| `maxRatio` | Limit/Request ratio | `maxRatio.memory: 4` (limit ≤ 4x request) |

### Phối hợp: LimitRange → ResourceQuota

```
LimitRange (namespace)
    ↓ auto-inject default nếu container không specify
Container có requests + limits
    ↓
Kubernetes scheduler
    ↓ sum tất cả requests/limits trong namespace
ResourceQuota (namespace)
    ↓ check against hard limit
Pass → Pod được schedule
Fail → Pod bị reject (Fails for quota)
```

### ResourceQuota vs LimitRange — So sánh

| Tiêu chí | ResourceQuota | LimitRange |
|---|---|---|
| Scope | Namespace-wide | Namespace-wide (trừ PodCluster) |
| Mục đích | Giới hạn tổng namespace | Default + range cho từng container/pod |
| Hard limit | Có (`spec.hard`) | Có (`max`, `min`) |
| Auto-inject | Không | Có (`default`, `defaultRequest`) |
| Khi reject | Khi tổng vượt quota | Khi container không satisfy min/max |
| Use case | Team quota | Enforce best practices |
| Check phase | Scheduler | Admission + Scheduler |

### Lưu ý quan trọng
- ResourceQuota và LimitRange đều là **namespace-scoped**
- ResourceQuota là **hard limit** — không thể vượt (reject ngay)
- LimitRange **tự động inject** — pod không cần specify requests/limits nếu có LimitRange
- Cả hai đều chạy ở **admission phase** — được kiểm tra trước khi Pod tạo
- Nếu pod không có `requests/limits` và không có LimitRange → pod có thể bị reject bởi ResourceQuota (vì sum = 0, nhưng BestEffort scope có thể không count)

---

## Section 3 — ResourceQuota + LimitRange Lab Keys

### Workflow tạo ResourceQuota + LimitRange

```
1. Tạo namespace
   kubectl create ns team-a

2. Tạo LimitRange (inject default)
   kubectl apply -f limitrange.yaml

3. Tạo ResourceQuota (hard limit)
   kubectl apply -f resourcequota.yaml

4. Tạo pod (không specify resources)
   → LimitRange auto-fill requests/limits
   → ResourceQuota check sum ≤ hard limit

5. Verify
   kubectl describe quota -n team-a
   kubectl describe limitrange -n team-a
   kubectl get pod <name> -n team-a -o jsonpath='{.spec.containers[*].resources}'
```

### Verify commands

```bash
# Xem ResourceQuota usage
kubectl describe quota -n <ns>
# Hiển thị: hard (limit) + used (current) + status

# Xem LimitRange
kubectl describe limitrange -n <ns>
# Hiển thị: default, defaultRequest, max, min

# Xem resources của pod (sau khi LimitRange inject)
kubectl get pod <name> -n <ns> -o jsonpath='{.spec.containers[*].resources}'

# Xem pod có bị reject không
kubectl describe pod <name> -n <ns>
# Tìm: Events → "FailedScheduling" hoặc "FailedCreate"
```

### Common errors

| Error message | Nguyên nhân | Cách fix |
|---|---|---|
| `Fails for quota` | Pod vượt ResourceQuota hard limit | Giảm requests/limits |
| `Exceeds the minimum memory` | Pod không satisfy LimitRange `min` | Tăng memory request |
| `Exceeds the maximum cpu` | Pod vượt LimitRange `max` | Giảm CPU limit |
| `Must specify non-zero` | Pod không có requests/limits và không có LimitRange | Thêm LimitRange hoặc specify resources |

---

## Section 4 — Chaos Engineering Keys

### Chaos Engineering — Workflow

```
1. Xây Steady-State Hypothesis
   "Hệ thống normal: latency P99 < 200ms, error rate < 0.1%"
       ↓
2. Inject Failure
   "Xóa 1 pod, thêm network latency 500ms"
       ↓
3. Observe
   "Latency tăng lên 500ms? Error rate tăng?"
       ↓
4. Learn
   "Hệ thống có auto-recovery? Cần circuit breaker?"
       ↓
5. Fix
   "Thêm HPA, circuit breaker, retry logic"
```

### Litmus Chaos — Kiến trúc

```
ChaosOperator (controller)
    ↓ quản lý experiments
ChaosEngine (CRD)
    ↓ define experiment config + target
ChaosExperiment (CRD — template)
    ↓ actual chaos logic
ChaosResult (CRD)
    ↓ lưu kết quả (pass/fail + verdict + events)
```

### Litmus — Workflow

```
1. Tạo ChaosExperiment CRD (template)
   - Định nghĩa loại chaos: pod-delete, network-latency, cpu-hog...

2. Tạo ChaosEngine CRD (instance)
   - Trỏ đến ChaosExperiment
   - Specify target: application label + namespace
   - Schedule: thời gian chạy

3. ChaosOperator nhận ChaosEngine
   - Tạo ChaosResult
   - Dispatch chaos vào target

4. Xem kết quả
   kubectl get chaosresult -n <ns>
   kubectl describe chaosresult <name> -n <ns>
```

### Chaos Mesh — Kiến trúc

```
ChaosController (controller manager)
    ↓ quản lý chaos resources
ChaosDaemon (agent trên mỗi node)
    ↓ thực thi chaos trên node/container
Sidecar DNS (optional)
    ↓ DNS chaos
```

### Chaos Mesh — Workflow

```
1. Tạo Chaos CRD trực tiếp
   - PodChaos, NetworkChaos, IOChaos, DNSChaos, HTTPChaos...

2. ChaosController nhận CRD
   - Dispatch qua ChaosDaemon

3. ChaosDaemon thực thi trên node
   - Kill pod / Add latency / Drop packets / Fill disk

4. Xem kết quả
   kubectl get <chaos-type> -n <ns>
   kubectl describe <chaos-type> <name> -n <ns>
```

### Litmus vs Chaos Mesh — So sánh

| Tiêu chí | Litmus Chaos | Chaos Mesh |
|---|---|---|
| Kiến trúc | Operator + ChaosEngine + ChaosExperiment | Controller + ChaosDaemon |
| Cài đặt | Helm | Helm |
| Experiment types | ~20+ | ~30+ |
| Fault types | Pod, Network, CPU, Memory, Disk | Pod, Network, I/O, DNS, HTTP, Time, Kernel |
| UI | Litmus Portal | Chaos Dashboard |
| CI integration | GitHub Actions, Jenkins | GitHub Actions, Jenkins |
| GitOps | ChaosEngine as CRD | Chaos as CRD |
| Learning curve | Thấp – Trung bình | Trung bình |
| Community | CNCF (lớn) | PingCap |
| Best for | Enterprise K8s, SRE team | Multi-layer chaos (network + I/O + kernel) |

### Các loại Chaos Experiment

| Loại | Litmus | Chaos Mesh | Mô tả |
|---|---|---|---|
| Pod failure | pod-delete | PodChaos (action: pod-kill) | Xóa/kill pod ngẫu nhiên |
| Network latency | network-chaos | NetworkChaos (latency) | Thêm delay vào network |
| Network loss | network-loss | NetworkChaos (loss) | Drop % packets |
| CPU stress | pod-cpu-hog | StressChaos (cpu) | Tạo CPU load 100% |
| Memory stress | pod-memory-hog | StressChaos (memory) | Fill memory |
| Disk fill | disk-fill | IOChaos | Fill disk space |
| DNS failure | — | DNSChaos | DNS resolution fail |
| HTTP failure | — | HTTPChaos | HTTP delay/abort |
| Time skew | — | TimeChaos | Thay đổi system time |

### Runbook vs Postmortem

| | Runbook | Postmortem |
|---|---|---|
| Mục đích | Phản ứng incident (chạy) | Phân tích sau incident (học hỏi) |
| Khi dùng | Trong khi incident xảy ra | Sau khi incident đã xử lý xong |
| Người dùng | On-call engineer | Team + stakeholders |
| Nội dung | Step-by-step commands | Timeline + root cause + remediation |
| Output | Incident được xử lý | Action items cho tương lai |

### Runbook Template — Các phần bắt buộc

```
1. Title + Description
   - Incident type + mô tả ngắn

2. Symptoms
   - Observable signs (metrics, logs, alerts)
   - Example: "Response time > 5s", "Pod crash loop", "Error rate > 5%"

3. Detection
   - Alert name + source (Prometheus, CloudWatch, etc.)
   - Runbook link trong alert message

4. Triage
   - Severity: P1 (critical) / P2 (high) / P3 (medium)
   - Impact scope: 1 service / team / org-wide
   - Blast radius: bao nhiêu users bị ảnh hưởng

5. Mitigation Steps (step-by-step)
   - Mỗi step: command + expected output + rollback
   - Time-box: mỗi step ≤ 15 phút

6. Rollback
   - Cách rollback nếu mitigation fail
   - Command + expected output

7. Escalation Path
   - Khi nào nhờ senior (time-box exceeded, step fail)
   - Contact: Slack channel, phone, email

8. Verification
   - Xác nhận incident đã fix
   - Metrics về normal range
   - User impact cleared

9. Postmortem Template (Google SRE Workbook)
   - Timeline
   - Root cause
   - Impact
   - Action items
```

### Google SRE Workbook — Postmortem template sections

| Section | Nội dung |
|---|---|
| Title | Incident summary (1 câu) |
| Severity | P1/P2/P3 + impact |
| Authors | Người viết + reviewers |
| Status | Ongoing / Resolved / Postmortem published |
| Timeline | Thời gian các sự kiện (UTC) |
| Blast radius | Số users/services bị ảnh hưởng |
| Root cause | Nguyên nhân kỹ thuật (1-2 đoạn) |
| Detection | Alert nào phát hiện, mất bao lâu |
| Mitigation | Các bước đã làm để fix |
| Action items | Các việc cần làm để không tái diễn |
| Lessons learned | Điều học được |

---

## Section 5 — Chaos Lab Keys

### Litmus — Quick commands

```bash
# Install Litmus
helm repo add litmus https://litmuschaos.github.io/litmus-helm/
helm install litmus litmus/litmus -n litmus --create-namespace

# Verify
kubectl get pods -n litmus

# Tạo ChaosExperiment (template)
kubectl apply -f chaos-experiment.yaml

# Tạo ChaosEngine (instance)
kubectl apply -f chaos-engine.yaml

# Xem kết quả
kubectl get chaosresult -n <ns>
kubectl describe chaosresult <name> -n <ns>

# Xóa experiment
kubectl delete chaosengine <name> -n <ns>
```

### Chaos Mesh — Quick commands

```bash
# Install Chaos Mesh
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace

# Verify
kubectl get pods -n chaos-mesh

# Tạo NetworkChaos
kubectl apply -f network-chaos.yaml

# Xem kết quả
kubectl get networkchaos -n <ns>
kubectl describe networkchaos <name> -n <ns>

# Xóa
kubectl delete networkchaos <name> -n <ns>
```

### Tabletop Exercise — Checklist

```
1. Chọn 1 incident scenario (ví dụ: "Pod crash loop do OOM")
2. Assign roles:
   - Incident Commander (IC)
   - Communications Lead
   - Technical Responder
   - Escalation Engineer
3. Chạy runbook theo timeline:
   - T=0: Alert → Triage
   - T=5m: Mitigation step 1
   - T=10m: Mitigation step 2 hoặc escalate
   - T=15m: Verify fix
4. Ghi lại:
   - Gì hoạt động?
   - Gì không hoạt động?
   - Gì cần cải thiện?
5. Cập nhật runbook với lessons learned
```

---

## Section 6 — AWS Cost Anomaly Detection Keys

### Kiến trúc hệ thống

```
AWS Cost Explorer (historical data: 3-12 tháng)
    ↓
Cost Anomaly Detection (ML model)
    ↓ train + predict
Detect anomaly → tạo AnomalyMonitor + AnomalySubscription
    ↓
SNS Topic → notification
    ↓
Alert → Email / Slack / Lambda → Action
```

### Các khái niệm chính

| Khái niệm | Giải thích | Ví dụ |
|---|---|---|
| AnomalyMonitor | Định nghĩa scope monitor | All accounts / specific service / specific tag |
| AnomalySubscription | Định nghĩa người nhận alert | Email team, SNS topic |
| Alert frequency | Real-time (hourly) hoặc Daily | Daily summary cho finance team |
| Anomaly confidence | ML confidence score | HIGH / MEDIUM / LOW |
| Anomaly total | Tổng chi bất thường | $5,000 spike |
| Anomaly period | Thời gian xảy ra anomaly | 2024-01-15 10:00–11:00 UTC |

### Cost Guard Pattern

```
ResourceQuota (Proactive)          Cost Anomaly Detection (Reactive)
    │                                      │
    ├── Giới hạn resource                 ├── Phát hiện cost spike
    ├── Ngăn over-provision               ├── Cảnh báo sớm
    ├── Prevent cost spike                ├── Trigger action (Lambda/Alert)
    └── Team-level control                └── Org-level visibility
                                              │
                              ┌─────────────────┴─────────────────┐
                              │         COST GUARD                  │
                              │  Proactive + Reactive protection   │
                              └─────────────────────────────────────┘
```

### ResourceQuota ↔ Cost Anomaly Detection — Mapping

| Layer | Tool | Kiểu | Action |
|---|---|---|---|
| Proactive | ResourceQuota + LimitRange | Prevent | Block over-provision trước |
| Reactive | AWS Cost Anomaly Detection | Detect | Phát hiện spike sau khi xảy ra |
| Hard limit | AWS Budgets | Enforce | Stop services khi vượt budget |
| Alert | SNS + Lambda | Notify | Gửi alert → auto-remediation |

### Cost Anomaly Detection — Alert flow

```
ML Model detect anomaly
    ↓
Tạo AnomalyEvent
    ↓
AnomalyMonitor match → filter
    ↓
AnomalySubscription → gửi notification
    ↓
SNS Topic → Email / Slack / Lambda
    ↓
Lambda action → stop EC2 / notify Slack channel
```

### AWS CLI commands

```bash
# Liệt kê monitors
aws ce get-anomaly-monitors

# Liệt kê subscriptions
aws ce get-anomaly-subscriptions

# Xem anomalies
aws ce get-anomalies --anomaly-monitor-arn <arn> --anomaly-detection-period <days>
```

### Best practices

- ResourceQuota cho namespace-level cost guard (proactive)
- Cost Anomaly Detection cho org-level cost visibility (reactive)
- AWS Budgets cho hard budget limit (enforce)
- Combine cả 3: ResourceQuota → Cost Anomaly Detection → AWS Budgets

---

## Tổng kết Keys

### Quick Decision Matrix

| Khi bạn cần... | Dùng gì | File tra cứu |
|---|---|---|
| Giới hạn team quota (CPU/RAM) | ResourceQuota | keys.md §2 |
| Default requests/limits cho containers | LimitRange | keys.md §2 |
| Inject chaos để test resilience | Litmus / Chaos Mesh | keys.md §4 |
| Viết runbook cho incident | Google SRE Workbook | keys.md §4 |
| Phát hiện cost spike sớm | AWS Cost Anomaly Detection | keys.md §6 |
| Hard budget limit | AWS Budgets | keys.md §6 |
| Tích hợp toàn stack | Full flow §1 | keys.md §1 |

### Final Checklist

- [ ] Vẽ được full flow 5 layers
- [ ] Tạo được LimitRange + ResourceQuota
- [ ] Chạy được Litmus ChaosExperiment
- [ ] Viết được runbook template
- [ ] Hiểu AWS Cost Anomaly Detection flow
- [ ] Giải thích được Cost Guard Pattern (proactive + reactive)

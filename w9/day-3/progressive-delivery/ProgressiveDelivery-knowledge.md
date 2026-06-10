# Progressive Delivery — Lý thuyết & Chiến lược

---

## 1. Tổng quan Progressive Delivery

**Progressive Delivery** là tập hợp các kỹ thuật deploy giúp giảm thiểu rủi ro bằng cách phân phối thay đổi đến người dùng một cách từ từ, có kiểm soát, thay vì switch hoàn toàn sang version mới.

```
┌──────────────────────────────────────────────────────────────────┐
│          PROGRESSIVE DELIVERY — WHY?                               │
│                                                                  │
│  Business:                                                       │
│    • Giảm downtime từ hours → minutes                            │
│    • Release feature mới mà không ảnh hưởng toàn bộ users         │
│    • Thu thập metrics thực tế trên production trước khi full rollout│
│                                                                  │
│  Technical:                                                       │
│    • Phát hiện lỗi sớm, rollback nhanh                         │
│    • Chia nhỏ blast radius (blast radius = users bị ảnh hưởng)  │
│    • Kết hợp với SLO để đưa ra quyết định deploy tự động        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Chiến lược Progressive Delivery

### 2.1 Canary Deployment

Chuyển % traffic dần dần sang version mới, monitor metrics ở mỗi bước.

```
Timeline của Canary:

  v1 (100%) ──────────────────────▶ v1 (0%)

  Step 1: v1(90%) + v2(10%) ────▶ verify 5 phút
  Step 2: v1(70%) + v2(30%) ────▶ verify 10 phút
  Step 3: v1(30%) + v2(70%) ────▶ verify 10 phút
  Step 4: v2 (100%) ──────────────▶ done

  Rollback: chỉ cần giảm % v2 về 0 (nhanh, không downtime)
```

**Các loại Canary:**

```
1. Percentage-based (đơn giản nhất)
   → 5% → 10% → 20% → 50% → 100%

2. Header/Cookie-based
   → Users có header X-Canary: always → luôn nhận v2
   → Phù hợp cho internal testing

3. Geography-based
   → Region A (10% users) → v2
   → Region B (90% users) → v1

4. Progressive % với analysis
   → Mỗi bước chạy Prometheus query
   → Auto-abort nếu metrics vi phạm
```

### 2.2 Blue/Green Deployment

Tạo môi trường song song, switch hoàn toàn khi green đã sẵn sàng.

```
                    ┌─────────────┐
                    │  Router    │
                    │  (switch)  │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
        ┌──────────┐            ┌──────────┐
        │ Blue (v1)│            │ Green(v2)│
        │ Active   │            │ Preview  │
        │ 100%     │            │ 0%      │
        └──────────┘            └──────────┘
              ▲                         │
              │      switch (tức thì)   │
              └─────────────────────────┘

  Ưu điểm: Instant rollback (switch lại router)
  Nhược điểm: Cần gấp đôi resource (2× replicas)
```

### 2.3 Feature Flags

Bật/tắt feature bằng config, không cần deploy code.

```python
# Feature Flag: không cần rollout mới
if feature_flags.is_enabled("new-checkout", user_id):
    return new_checkout_flow()
else:
    return old_checkout_flow()

# Phổ biến: LaunchDarkly, Split.io, Unleash, Flagsmith
```

### 2.4 A/B Testing

Chia traffic theo rule cụ thể để so sánh conversion rate.

```
Traffic split:

  Request → Router → v1 (80%) ──▶ Original checkout
                    └→ v2 (20%) ──▶ New checkout

  → So sánh: conversion rate, revenue, engagement
  → Dùng kết quả để quyết định full rollout
```

---

## 3. So sánh chi tiết Canary vs Blue/Green

| Tiêu chí | Canary | Blue/Green |
|---|---|---|
| **Resource** | % của replicas hiện tại | 2× replicas song song |
| **Risk** | Thấp (chỉ % users dùng v2) | Trung bình (switch hoàn toàn) |
| **Rollback speed** | Tức thì (giảm %) | Tức thì (switch router) |
| **Cost** | Thấp (chỉ tăng thêm vài replicas) | Cao (2× resources) |
| **Use case tốt** | Progressive verification, SLO-based | Instant switch, compliance |
| **Testing** | Real users (canary), safe | Full staging trên prod |
| **Automation** | Dễ tích hợp SLO/analysis | Khó hơn (cần pre/post checks) |

---

## 4. Traffic Management — Các cách chia traffic

### 4.1 Pod Selector (cơ bản — không cần Ingress)

```yaml
# Canary chia ReplicaSet:
# - v1 stable: 9 replicas
# - v2 canary: 1 replica
# → v2 nhận ~10% traffic

# Argo Rollouts quản lý:
spec:
  replicas: 10
  strategy:
    canary:
      steps:
        - setWeight: 10
        # Argo Rollouts scale v2 lên 1 replica (10% of 10)
        # v1 còn lại 9 replicas (90%)
```

**Lưu ý:** Cách này chỉ hoạt động khi Service dùng `random` hoặc `round-robin` load balancing. Với `sessionAffinity`, traffic không chia theo %.

### 4.2 NGINX Ingress Controller

```yaml
# Argo Rollouts update Ingress annotation:
annotations:
  nginx.ingress.kubernetes.io/canary-weight: "20"
  # Khi promote, giá trị tăng: 20 → 40 → 60 → 100
```

### 4.3 SMI (Service Mesh Interface)

```yaml
# Traffic Split CRD (SMI spec)
apiVersion: split.smi-spec.io/v1alpha3
kind: TrafficSplit
metadata:
  name: hello-split
spec:
  service: hello
  backends:
    - service: hello-stable
      weight: 80
    - service: hello-canary
      weight: 20
```

### 4.4 Istio VirtualService

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: hello
spec:
  hosts:
    - hello
  http:
    - route:
        - destination:
            host: hello-stable
            subset: v1
          weight: 80
        - destination:
            host: hello-canary
            subset: v2
          weight: 20
```

### 4.5 AWS ALB / CloudFront

```yaml
# Argo Rollouts integration với AWS ALB:
trafficRouting:
  alb:
    rootNode: nginx.ingress.kubernetes.io
    annotationValue: |
      annotation: value
```

---

## 5. Abort Criteria — Khi nào nên rollback

### 5.1 Metrics-based (dùng AnalysisTemplate)

```
Abort nếu BẤT KỲ điều kiện nào sau đây xảy ra:

  ❌ Success rate < 99.5%
  ❌ Error rate > 0.5%
  ❌ p99 latency > 1000ms
  ❌ Burn rate > 14.4× (fast burn)
  ❌ HTTP 5xx rate > 1%
  ❌ Custom business metric violation
```

### 5.2 Manual Gate

```
Step pause {} → Dừng tại đây
→ Team lead / SRE review metrics
→ Quyết định: promote HOẶC abort

Các câu hỏi cần trả lời trước khi promote:
  □ Error rate của canary có cao hơn stable?
  □ Latency của canary có tăng đáng kể?
  □ Có alerts nào firing?
  □ Metrics có trending theo hướng xấu?
```

### 5.3 Automated Gate (AnalysisTemplate + Prometheus)

```
Argo Rollouts chạy Prometheus queries định kỳ
  → Kết quả pass → tự động promote
  → Kết quả fail → tự động abort

Đây là cách tốt nhất cho auto-pilot (SRE/SE methodology)
```

---

## 6. Integration với SLO Burn Rate

Khi dùng burn rate alerts (từ Day-2), ta có thể kết hợp trong Progressive Delivery:

```
┌──────────────────────────────────────────────────────────────────┐
│              PROGRESSIVE DELIVERY + BURN RATE                      │
│                                                                  │
│  1. Canary 10% → Argo Rollouts chạy Analysis                    │
│                   → Prometheus query: burn_rate                  │
│                                                                  │
│  2. Burn rate > 14.4× trong 5 phút                             │
│     → AnalysisTemplate fail                                      │
│     → Argo Rollouts ABORT                                       │
│     → Canary scale down về 0                                   │
│     → Stable tiếp tục nhận 100% traffic                         │
│                                                                  │
│  3. Không tốn thêm Error Budget                                 │
│     → Thay vì incident tiếp tục ảnh hưởng 100% users          │
│     → Chỉ 10% users bị ảnh hưởng trong thời gian canary        │
│                                                                  │
│  4. On-call được notify khi abort                              │
│     → Alert → Slack → PagerDuty                                │
│     → Investigation bắt đầu ngay lập tức                        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 7. Rollback Strategies

### 7.1 Tự động (Automated)

```yaml
# Argo Rollouts: tự động rollback khi analysis fail
strategy:
  canary:
    abortScaleDownDelaySeconds: 300  # Scale down sau 5 phút
```

```bash
# Rollback bằng argo rollouts
kubectl argo rollouts abort hello
kubectl argo rollouts undo hello
```

### 7.2 Manual

```bash
# Undo về revision trước
kubectl argo rollouts undo hello -n default

# Undo về revision cụ thể
kubectl argo rollouts undo hello --to-revision=3 -n default

# Promote (tiếp tục rollout)
kubectl argo rollouts promote hello -n default

# Abort
kubectl argo rollouts abort hello -n default
```

### 7.3 GitOps Rollback (ArgoCD)

```bash
# Rollback bằng Git (phù hợp với GitOps)
git checkout <tag-v1.0> -- ./apps/my-app/
git commit -m "Rollback to v1.0"
git push origin main

# ArgoCD tự động sync cluster về v1.0
# Argo Rollouts nhận manifest mới → rollback
```

---

## 8. Best Practices cho Progressive Delivery

```
✅ LUÔN LUÔN có metrics trước khi canary
   → Không canary nếu không có monitoring

✅ Bắt đầu với % nhỏ (1-5%)
   → Ít users bị ảnh hưởng nếu có vấn đề

✅ Đủ thời gian ở mỗi step
   → Tối thiểu 5-10 phút để collect metrics
   → Đủ cho một vài SLO evaluation cycles

✅ Đặt abort criteria rõ ràng
   → Success rate threshold
   → Latency threshold
   → Burn rate threshold

✅ Rollback nhanh hơn deploy
   → Luôn có rollback plan sẵn sàng

✅ Canary ở production, không chỉ staging
   → Real users + real traffic = best signal

✅ Theo dõi business metrics, không chỉ technical
   → Conversion rate, revenue, engagement
   → Technical metrics OK nhưng business metrics drop → abort
```

---

## Tổng kết

| Chiến lược | % traffic | Rollback | Cost |
|---|---|---|---|
| **Canary** | Tăng dần (5% → 100%) | Tức thì | Thấp |
| **Blue/Green** | Switch hoàn toàn | Tức thì (router) | Cao (2×) |
| **A/B Testing** | Chia theo rule | Tức thì | Trung bình |
| **Feature Flags** | Config-based | Tức thì | Thấp |

| Thành phần | Vai trò |
|---|---|
| **Rollout CRD** | Declarative rollout definition |
| **AnalysisTemplate** | Automated verification (Prometheus queries) |
| **Burn Rate Alert** | SLO-based abort criteria |
| **Ingress/Service Mesh** | Traffic splitting |
| **ArgoCD** | GitOps + progressive delivery sync |

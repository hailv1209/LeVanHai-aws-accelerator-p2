# SLO Alerting — Lý thuyết & Cú pháp

---

## 1. Tại sao cần Alerting khác cho SLO?

**Vấn đề với alerting truyền thống:**

```
Alert truyền thống:
  "Error rate > 1% trong 5 phút liên tục"

→ Vấn đề: Brief spike (2-3 phút) cũng trigger alert
→ Vấn đề: Không phân biệt:
  - "10% lỗi trong 3 phút" (lỗi lớn nhưng ngắn)
  - "1.1% lỗi trong 2 giờ" (lỗi nhỏ nhưng kéo dài)
→ Vấn đề: Không liên quan đến Error Budget
```

**SLO Alerting:**

```
→ Alert DỰA TRÊN Error Budget — không phải threshold cố định
→ Phân biệt được fast burn (incident nghiêm trọng) vs slow burn (degradation âm thầm)
→ Đúng thời điểm: alert trước khi budget hết, không alert khi không cần
```

---

## 2. Burn Rate — Khái niệm cốt lõi

### 2.1 Định nghĩa

```
Burn Rate = Tốc độ tiêu thụ Error Budget thực tế
            ─────────────────────────────────────
            Tốc độ tiêu thụ Error Budget cho phép

Burn Rate = Error Rate Thực Tế / Error Rate Cho Phép (theo SLO)

Ví dụ: SLO 99.9% (cho phép 0.1% error)
  - Error cho phép = 0.1% (trong toàn bộ 30 ngày)
  - Error thực tế = 1% (trong 5 phút)

  Burn Rate = 1% / 0.1% = 10×

  → Nghĩa là: đang tiêu thụ error budget nhanh gấp 10 lần cho phép
  → Với tốc độ này, 1% error budget sẽ hết trong ~3 giờ
```

### 2.2 Công thức tính Burn Rate

```
Cho SLO 99.9% (error budget = 0.1% trong 30 ngày):

Error rate cho phép (trên phút):
  = 0.001 / (30 × 24 × 60)
  = 0.001 / 43,200
  = 0.00000002315% / phút

Burn Rate (trong 5 phút window):
  = (Actual error rate trong 5 phút) / (Error rate cho phép)
  = (sum(rate(errors[5m])) / sum(rate(total[5m]))) / 0.00000002315

  Hoặc đơn giản hơn:
  Burn Rate = (1 - Actual Availability) / (1 - SLO)
             × (Window_30d / Evaluation_Window)

  Trong Prometheus:
  burn_rate = (1 - availability_5m) / (1 - 0.999) * (30d / 5m)
            = (error_rate_5m / 0.001) * (8640 / 1)
            = error_rate_5m / 0.001 * 8640
```

### 2.3 Tốc độ hết Error Budget theo Burn Rate

```
┌──────────────────────────────────────────────────────────────────┐
│          ERROR BUDGET EXHAUSTION TIME (SLO 99.9%, 30 ngày)        │
│          Error Budget = 43.2 phút                                 │
├────────────────┬───────────────────────┬──────────────────────────┤
│  Burn Rate    │  % Budget tiêu/giờ   │  Hết budget trong       │
├────────────────┼───────────────────────┼──────────────────────────┤
│  1× (tốc độ   │  ~0.14%              │  ~30 ngày               │
│    bình thường)│                       │  (Không alert)          │
├────────────────┼───────────────────────┼──────────────────────────┤
│  10×           │  ~1.4%               │  ~3 ngày               │
│                │                       │  (Alert warning)        │
├────────────────┼───────────────────────┼──────────────────────────┤
│  50×           │  ~7%                 │  ~14 giờ               │
│                │                       │  (Alert critical)       │
├────────────────┼───────────────────────┼──────────────────────────┤
│  100×          │  ~14%                │  ~7 giờ                │
│                │                       │  (Alert P1)            │
├────────────────┼───────────────────────┼──────────────────────────┤
│  1000×         │  ~140%                │  ~43 phút              │
│                │                       │  (Alert P0)            │
└────────────────┴───────────────────────┴──────────────────────────┘
```

---

## 3. Multi-window Burn Rate Alerting

### 3.1 Nguyên tắc

```
┌─────────────────────────────────────────────────────────────────┐
│          MULTI-WINDOW BURN RATE ALERTING                         │
│          (Google SRE Blue Book, Chapter 5)                       │
│                                                                  │
│  Fast Window (ngắn):                                             │
│    - Window: 5 phút, Evaluation: 5 phút                         │
│    - Burn Rate threshold: 14.4×                                 │
│    - Alert khi: error rate cao BẤT THƯỜNG (incident nghiêm trọng)│
│    - Tốc độ: 1% budget/giờ                                      │
│    - Mục đích: alert NGAY cho major outage                      │
│                                                                  │
│  Slow Window (dài):                                              │
│    - Window: 1 giờ, Evaluation: 10 phút                        │
│    - Burn Rate threshold: 6.48×                                 │
│    - Alert khi: error rate thấp nhưng KÉO DÀI (degradation)     │
│    - Tốc độ: 0.5% budget/giờ                                   │
│    - Mục đích: phát hiện degradation âm thầm                    │
│                                                                  │
│  → Tránh false positive: brief spike không trigger               │
│  → Tránh false negative: slow burn vẫn được phát hiện           │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Alerting Rules — Cú pháp Prometheus

```yaml
groups:
  - name: slo_burn_rate_alerts
    interval: 30s  # evaluation interval
    rules:

      # ─── FAST BURN: 5 phút × 5 phút ───
      # Trigger: burn rate > 14.4× trong 5 phút
      # = 1% error budget tiêu thụ trong 1 giờ
      # → Major incident, alert NGAY
      - alert: SLIBurningFast
        expr: |
          (
            sum(rate(http_requests_total{status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total[5m]))
          )
          /
          (
            (1 - 0.999)          # SLO 99.9%
            /
            (24 * 60)            # 30 ngày tính ra phút
          )
          > 14.4
        labels:
          severity: critical
          slo: availability
          burn_rate: fast
        annotations:
          summary: |
            Fast burn rate detected: {{ $value | printf "%.1f" }}×
          description: |
            Burn rate {{ $value | printf "%.1f" }}× trong cửa sổ 5 phút.
            Đang tiêu thụ 1% error budget trong mỗi giờ.
            Nếu tiếp tục, budget sẽ hết trong < 4 ngày.
            Action: Investigate immediately!

      # ─── MEDIUM BURN: 30 phút × 30 phút ───
      # Trigger: burn rate > 6.48× trong 30 phút
      # = 1% error budget tiêu thụ trong 6 giờ
      # → Persistent degradation, alert sớm
      - alert: SLIBurningMedium
        expr: |
          (
            sum(rate(http_requests_total{status=~"5.."}[30m]))
            /
            sum(rate(http_requests_total[30m]))
          )
          /
          (
            (1 - 0.999)
            /
            (24 * 60)
          )
          > 6.48
        labels:
          severity: warning
          slo: availability
          burn_rate: medium
        annotations:
          summary: |
            Medium burn rate: {{ $value | printf "%.1f" }}×
          description: |
            Burn rate {{ $value | printf "%.1f" }}× trong cửa sổ 30 phút.
            Đang tiêu thụ 1% error budget trong mỗi 6 giờ.
            Nếu tiếp tục, budget sẽ hết trong ~3 tuần.
            Action: Investigate within 24 hours.

      # ─── SLOW BURN: 1 giờ × 10 phút ───
      # Trigger: burn rate > 6.48× trong 1 giờ
      # → Slow degradation (âm thầm)
      - alert: SLIBurningSlow
        expr: |
          (
            sum(rate(http_requests_total{status=~"5.."}[1h]))
            /
            sum(rate(http_requests_total[1h]))
          )
          /
          (
            (1 - 0.999)
            /
            (24 * 60)
          )
          > 6.48
        labels:
          severity: warning
          slo: availability
          burn_rate: slow
        annotations:
          summary: |
            Slow burn rate: {{ $value | printf "%.1f" }}×
          description: |
            Slow burn rate {{ $value | printf "%.1f" }}× trong cửa sổ 1 giờ.
            Đang có persistent degradation với tốc độ thấp.
            Error budget sẽ hết trong ~3 tuần nếu không fix.
            Action: Schedule investigation.

      # ─── BUDGET EXHAUSTION: 1 giờ × 5 phút ───
      # Trigger: 10% budget đã dùng trong 1 giờ
      - alert: SLOBudget10pctConsumed1h
        expr: |
          (
            1 - (
              sum(rate(http_requests_total{status=~"2.."}[1h]))
              /
              sum(rate(http_requests_total[1h]))
            )
          )
          /
          (1 - 0.999)
          * 100
          > 10
        labels:
          severity: warning
          policy: error-budget
        annotations:
          summary: "10% error budget consumed in 1 hour"
          description: "{{ $labels.sloth }} service đã tiêu thụ 10% error budget trong 1 giờ."

      # ─── BUDGET EXHAUSTION: 50% ───
      - alert: SLOBudgetHalfConsumed
        expr: |
          (
            1 - (
              sum(rate(http_requests_total{status=~"2.."}[30d]))
              /
              sum(rate(http_requests_total[30d]))
            )
          )
          /
          (1 - 0.999)
          * 100
          > 50
        labels:
          severity: warning
          policy: error-budget
        annotations:
          summary: "50% error budget consumed — reduce deploy velocity"
          description: |
            Đã tiêu thụ {{ $value | printf "%.0f" }}% error budget.
            Khuyến nghị: Giảm tốc độ deploy, ưu tiên stability.

      # ─── BUDGET EXHAUSTION: 90% ───
      - alert: SLOBudgetExhausted
        expr: |
          (
            1 - (
              sum(rate(http_requests_total{status=~"2.."}[30d]))
              /
              sum(rate(http_requests_total[30d]))
            )
          )
          /
          (1 - 0.999)
          * 100
          > 90
        labels:
          severity: critical
          policy: error-budget
        annotations:
          summary: "90% error budget consumed — STOP DEPLOY NOW"
          description: |
            Đã tiêu thụ {{ $value | printf "%.0f" }}% error budget!
            Action: Ngừng deploy ngay lập tức, ưu tiên reliability.
            Xem postmortem: https://wiki.example.com/postmortems
```

---

## 4. Latency SLO Alerts

```yaml
groups:
  - name: slo_latency_alerts
    interval: 30s
    rules:

      # Fast burn latency: p99 > 1s trong 5 phút
      - alert: SLOLatencyFastBurn
        expr: |
          (
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
            ) / 1.0  # threshold = 1s
          )
          > 1.0
        labels:
          severity: critical
          slo: latency
        annotations:
          summary: "p99 latency {{ $value | printf "%.0f" }}ms exceeds 1s threshold"
          description: |
            p99 latency = {{ $value | printf "%.0f" }}ms trong 5 phút.
            Alert này cho thấy severe latency degradation.

      # Slow burn latency: p95 > 500ms trong 1 giờ
      - alert: SLOLatencySlowBurn
        expr: |
          (
            histogram_quantile(0.95,
              sum(rate(http_request_duration_seconds_bucket[1h])) by (le)
            ) / 0.5  # threshold = 500ms
          )
          > 1.0
        labels:
          severity: warning
          slo: latency
        annotations:
          summary: "p95 latency elevated for 1 hour"
          description: |
            p95 latency = {{ $value | printf "%.0f" }}ms trong 1 giờ.
            Đây là slow burn về latency.

      # SLO compliance: <95% requests đạt latency target
      - alert: SLOLatencyComplianceBreach
        expr: |
          (
            sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m]))
            /
            sum(rate(http_request_duration_seconds_count[5m]))
          )
          < 0.95
        labels:
          severity: warning
          slo: latency
        annotations:
          summary: "Latency SLO compliance < 95% — only {{ $value | printf "%.1f" }}%"
          description: |
            Chỉ {{ $value | printf "%.1f" }}% requests đạt latency < 500ms trong 5 phút.
            SLO target: 95% compliance.
```

---

## 5. PrometheusRule CRD cho Kubernetes

```yaml
# slo-prometheusrule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-burn-rate-alerts
  labels:
    prometheus: rules
    release: prometheus
spec:
  groups:
    - name: slo_burn_rate_alerts
      interval: 30s
      rules:
        # Recording rule: availability SLI (pre-compute)
        - record: slo:availability:5m
          expr: |
            sum(rate(http_requests_total{status=~"2.."}[5m]))
            /
            sum(rate(http_requests_total[5m]))

        - record: slo:error_budget_consumed:30d
          expr: |
            (
              1 - (
                sum(rate(http_requests_total{status=~"2.."}[30d]))
                /
                sum(rate(http_requests_total[30d]))
              )
            )
            /
            (1 - 0.999)

        # Fast burn rate
        - alert: SLIBurningFast
          expr: |
            (
              1 - slo:availability:5m
            )
            /
            (
              (1 - 0.999)
              /
              (24 * 60)
            )
            > 14.4
          for: 5m
          labels:
            severity: critical
            slo: availability
          annotations:
            summary: "Fast burn: {{ $value | printf '%.1f' }}×"
            description: "Error budget đang tiêu thụ nhanh gấp {{ $value | printf '%.1f' }}x bình thường"

        # Slow burn rate
        - alert: SLIBurningSlow
          expr: |
            (
              1 - (
                sum(rate(http_requests_total{status=~"2.."}[1h]))
                /
                sum(rate(http_requests_total[1h]))
              )
            )
            /
            (
              (1 - 0.999)
              /
              (24 * 60)
            )
            > 6.48
          for: 10m
          labels:
            severity: warning
            slo: availability
          annotations:
            summary: "Slow burn: {{ $value | printf '%.1f' }}×"
            description: "Persistent degradation — tiêu thụ budget chậm nhưng liên tục"

        # Budget exhaustion
        - alert: SLOBudgetExhausted
          expr: slo:error_budget_consumed:30d > 0.9
          for: 0m
          labels:
            severity: critical
            policy: error-budget
          annotations:
            summary: "Error budget đã dùng {{ $value | printf '%.0f' }}%!"
            description: |
              Đã tiêu thụ {{ $value | printf '%.0f' }}% error budget trong 30 ngày.
              STOP DEPLOY — Ưu tiên stability.
```

---

## 6. Alert Severity Matrix

```
┌─────────────────────────────────────────────────────────────────┐
│                    ALERT SEVERITY & RESPONSE                      │
│                                                                  │
│  🚨 P0 / Critical                                               │
│     Fast burn: burn_rate > 14.4× trong 5 phút                   │
│     Action: Page on-call immediately, all hands on deck          │
│     SLA: Respond < 5 phút                                        │
│                                                                  │
│  🔴 P1 / Warning                                                │
│     Medium burn: burn_rate > 6.48× trong 30 phút                 │
│     Action: On-call respond within 30 phút                        │
│     SLA: Respond < 30 phút                                       │
│                                                                  │
│  🟡 P2 / Warning                                                │
│     Slow burn: burn_rate > 6.48× trong 1 giờ                    │
│     Action: Schedule investigation, notify team                   │
│     SLA: Respond < 4 giờ                                         │
│                                                                  │
│  🟢 P3 / Info                                                   │
│     Budget exhausted > 50% (30 ngày)                             │
│     Action: Update stakeholders, slow deploy velocity              │
│     SLA: Respond < 24 giờ                                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tổng kết

| Alert | Window | Threshold | Ý nghĩa |
|---|---|---|---|
| `SLIBurningFast` | 5m × 5m | burn_rate > 14.4× | Major incident |
| `SLIBurningMedium` | 30m × 30m | burn_rate > 6.48× | Persistent degradation |
| `SLIBurningSlow` | 1h × 10m | burn_rate > 6.48× | Slow degradation |
| `SLOBudget10pct` | 1h | 10% budget consumed | Early warning |
| `SLOBudgetHalf` | 30d | 50% budget consumed | Reduce deploy |
| `SLOBudgetExhausted` | 30d | 90% budget consumed | STOP DEPLOY |

# SLO / SLI / SLA — Lý thuyết & cú pháp

---

## 1. Tổng quan — Ba khái niệm cốt lõi

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│    SLI      │────▶│    SLO      │────▶│    SLA      │
│ (Indicator) │     │ (Objective) │     │ (Agreement) │
└─────────────┘     └─────────────┘     └─────────────┘
   Đo lường            Mục tiêu          Cam kết
   (thực tế)          (mong muốn)       (pháp lý)
```

| Khái niệm | Ý nghĩa | Ai đặt |
|---|---|---|
| **SLI** | Chỉ số đo lường thực tế (con số cụ thể) | Hệ thống tự sinh ra |
| **SLO** | Mục tiêu mà team đặt ra cho SLI | Team nội bộ |
| **SLA** | Cam kết pháp lý với khách hàng bên ngoài | Legal / Business |

### 2. SLI (Service Level Indicator)

**SLI** là metric cụ thể ta thu thập được từ hệ thống. Đây là dữ liệu thô, đo lường thực tế.

**Công thức tổng quát:**

```
SLI = Good Events / Valid Events
```

**Các loại SLI phổ biến:**

```
HTTP/gRPC Service:
  ├── Availability  = successful requests / total requests
  │                   (successful = không phải 5xx, không timeout)
  ├── Latency      = p50/p90/p95/p99 response time (ms)
  ├── Throughput   = requests per second (RPS)
  └── Error Rate   = error requests / total requests

Database / Storage:
  ├── Query latency   = p99 query duration
  ├── Connection pool = active connections / max connections
  ├── Replication lag = delay between primary và replica (ms)
  └── Storage usage  = used bytes / total bytes

Queue / Message Broker:
  ├── Message lag    = consumer offset lag
  ├── Queue depth    = số message đang chờ
  ├── Processing rate = messages processed per second
  └── DLQ (Dead Letter Queue) count

Infrastructure:
  ├── CPU usage      = used / total CPU cycles
  ├── Memory usage   = used / total memory
  ├── Disk I/O       = read/write throughput
  └── Network        = bytes transmitted / bandwidth
```

### 3. SLO (Service Level Objective)

**SLO** là mục tiêu cụ thể mà ta đặt ra cho SLI. Đây là "cam kết nội bộ" — ta muốn SLI đạt được mức này.

**Cú pháp đặt SLO chuẩn:**

```
<SLI metric> <operator> <threshold> measured over <window>

Ví dụ:
  "Tỷ lệ request thành công ≥ 99.9% measured over 30-day rolling window"
  "p99 response time < 500ms measured over 5-minute window"
```

**SLO phổ biến theo loại service:**

| Service type | SLO phổ biến |
|---|---|
| High-traffic web (Shopify, Netflix) | 99.99% availability |
| Standard API / SaaS | 99.9% availability |
| Batch / Background job | 99.0% availability |
| Critical infrastructure | 99.999% (five nines) |

**Bảng chuyển đổi SLO → downtime cho phép:**

| SLO | Downtime / ngày | Downtime / tuần | Downtime / tháng | Downtime / năm |
|---|---|---|---|---|
| 99% | 14.4 phút | 1.68 giờ | 7.31 giờ | 3.65 ngày |
| 99.9% | 1.44 phút | 10.1 phút | 43.8 phút | 8.76 giờ |
| 99.95% | 43.2 giây | 5.04 phút | 21.9 phút | 4.38 giờ |
| 99.99% | 8.64 giây | 1.01 phút | 4.38 phút | 52.6 phút |
| 99.999% | 0.864 giây | 6.05 giây | 26.3 giây | 5.26 phút |

### 4. SLA (Service Level Agreement)

**SLA** là cam kết pháp lý, thường được ghi trong hợp đồng với khách hàng.

```
Quy tắc vàng:
  SLA ≤ SLO ≥ SLI thực tế

Tức là:
  - SLA thường "nới lỏng" hơn SLO (để buffer)
  - SLO thường nghiêm ngặt hơn SLA (để chủ động)
  - SLI thực tế phải ≥ SLO (đạt mục tiêu)

Ví dụ:
  SLA với khách hàng: 99.5% uptime
  SLO nội bộ:         99.9% uptime   ← nghiêm ngặt hơn SLA
  SLI thực tế:        99.92%        ← đạt SLO ✅
```

### 5. Error Budget

**Error Budget** = lượng lỗi cho phép trong kỳ đo = `1 - SLO`

```
Công thức:
  Error Budget = (1 - SLO%) × Total Time in Window
  Error Budget (%) = (1 - SLO%) × 100

Ví dụ: SLO 99.9%, kỳ 30 ngày
  Error Budget = 0.001 × 43,200 phút = 43.2 phút

  Nghĩa là: trong 30 ngày, hệ thống được phép
  downtime / lỗi tối đa 43.2 phút
```

**Error Budget Policy:**

```
Error Budget còn (>50%):
  ✅ Deploy tích cực — reliability đã đạt mục tiêu
  ✅ Experiment với feature mới
  ✅ Chấp nhận rủi ro calculated

Error Budget còn (<50%):
  ⚠️ Cảnh báo — giảm tốc độ deploy
  ⚠️ Ưu tiên bug fixes và stability

Error Budget đã dùng hết:
  🚨 Ngừng deploy hoàn toàn
  🚨 Ưu tiên tuyệt đối cho reliability
  🚨 Postmortem và action items bắt buộc
```

### 6. Availability SLO — Cú pháp & công thức

**Định nghĩa:**

```
Availability SLO = Good Events / Total Events × 100%

Trong đó:
  Good Events = request trả về status thuộc acceptable range
              (thường là 2xx, có thể thêm 3xx redirect)
  Total Events = tất cả request hợp lệ (không tính client abort)
```

**PromQL cho Availability SLI:**

```promql
-- Availability cơ bản
sum(rate(http_requests_total{status=~"2.."}[5m]))
/
sum(rate(http_requests_total[5m]))

-- Availability riêng cho từng service
sum(rate(http_requests_total{service="payment",status=~"2.."}[5m])) by (service)
/
sum(rate(http_requests_total{service="payment"}[5m])) by (service)

-- Availability theo endpoint
sum(rate(http_requests_total{path="/api/orders",status=~"2.."}[5m])) by (path)
/
sum(rate(http_requests_total{path="/api/orders"}[5m])) by (path)
```

### 7. Latency SLO — Cú pháp & công thức

**Định nghĩa:**

```
Latency SLO = tỷ lệ requests hoàn thành trong threshold

Ví dụ: "95% requests có response time < 500ms"
  = histogram_quantile(0.95, duration ≤ 500ms) × 100%
```

**Các loại percentile:**

```
p50 (median) : 50% requests nhanh hơn giá trị này
               → Nửa số users hài lòng
p90           : 90% requests nhanh hơn → phổ biến cho UX targets
p95           : 95% requests nhanh hơn → thường dùng cho SLA
p99           : 99% requests nhanh hơn → critical paths, infra
p999          : 99.9% requests nhanh hơn → financial transactions
```

**PromQL cho Latency SLI:**

```promql
-- p99 latency (nhân 1000 để đổi sang ms)
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000

-- p95 latency riêng theo service
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
) * 1000

-- SLO compliance: tỷ lệ request < 500ms
sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m]))
/
sum(rate(http_request_duration_seconds_count[5m]))
-- Kết quả: 0.987 = 98.7% requests < 500ms

-- Latency SLO multi-threshold (dùng histogram buckets)
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
histogram_quantile(0.999, rate(http_request_duration_seconds_bucket[5m]))
```

### 8. Composite SLO — Kết hợp nhiều SLI

Khi một service cần đồng thời đạt cả availability và latency:

```
Composite SLO = Availability AND Latency

Ví dụ: "99.9% requests thành công VÀ < 500ms"
  → Khi cả hai điều kiện đều thỏa mãn → SLO đạt
  → Khi một trong hai vi phạm → SLO vi phạm
```

```promql
-- Composite: availability ≥ 99.9% AND p99 latency < 500ms
(
  sum(rate(http_requests_total{status=~"2.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
) >= 0.999
and
(
  histogram_quantile(0.99,
    sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
  ) * 1000 < 500
)
```

---

## Tổng kết cú pháp

| Khái niệm | Cú pháp / Công thức | Output |
|---|---|---|
| **Availability SLI** | `sum(rate(http_requests_total{status=~"2.."})) / sum(rate(http_requests_total))` | `0.9995` (99.95%) |
| **Latency SLI (p99)** | `histogram_quantile(0.99, sum(rate(duration_bucket)) by (le)) * 1000` | `423` (ms) |
| **Error Budget** | `(1 - SLO%) × total_minutes_in_window` | `43.2 phút` |
| **Budget consumed** | `(1 - actual_availability) / (1 - SLO)` | `0.52` (52%) |
| **Composite SLO** | `availability_sli >= SLO AND latency_sli < threshold` | `true/false` |

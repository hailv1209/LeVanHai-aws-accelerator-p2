# Grafana cho TF3 Self-Heal Engine trên AWS

## 1. Grafana là gì?

**Grafana** là công cụ dùng để **hiển thị, quan sát và phân tích dữ liệu vận hành hệ thống**.

Grafana thường không tự sinh dữ liệu chính. Nó kết nối tới các nguồn dữ liệu như:

- **Prometheus / Amazon Managed Service for Prometheus**: metrics
- **CloudWatch**: metrics, logs, alarms của AWS
- **Loki**: logs
- **Tempo / X-Ray**: traces
- **PostgreSQL / MySQL / Athena**: dữ liệu dạng bảng hoặc audit query

Hiểu đơn giản:

```text
Prometheus / CloudWatch / Loki / Tempo = nơi chứa dữ liệu
Grafana = nơi xem dữ liệu, làm dashboard, debug và demo
```

---

## 2. Grafana có tác dụng gì trong TF3?

TF3 là đề tài **Self-Heal Engine** cho hệ thống Kubernetes. Pipeline chính:

```text
detect → match runbook → execute → verify → escalate nếu fail
```

Grafana giúp team CDO chứng minh pipeline này chạy thật.

Các tác dụng chính:

1. **Quan sát cluster**
   - Pod restart
   - OOMKilled
   - CPU / memory
   - Deployment replica
   - Queue backlog
   - Error rate / latency

2. **Quan sát Self-Heal Engine**
   - Bao nhiêu alert đã nhận
   - Pattern nào được detect
   - Runbook nào được chọn
   - Action nào đã execute
   - Verify thành công hay thất bại
   - Có rollback hay escalation không

3. **Làm evidence cho capstone**
   - Số scenario đã inject
   - Auto-resolve rate
   - Unsafe action = 0
   - Rollback count
   - Escalation count
   - Latency của `/v1/detect`, `/v1/decide`, `/v1/verify`

4. **Hỗ trợ demo và Q&A**
   - Khi mentor hỏi “làm sao biết engine tự heal thành công?”, mở Grafana dashboard để show metric trước/sau action.

---

## 3. Grafana liên kết với service khác như thế nào?

### Kiến trúc tổng quát cho TF3

```text
EKS / Kubernetes workloads
  ├── metrics
  │     ↓
  │  Prometheus hoặc Amazon Managed Service for Prometheus
  │     ↓
  │  Grafana dashboard
  │
  ├── logs
  │     ↓
  │  CloudWatch Logs hoặc Loki
  │     ↓
  │  Grafana log panel / Explore
  │
  ├── alert
  │     ↓
  │  Alertmanager / CloudWatch Alarm
  │     ↓
  │  Self-Heal Engine
  │     ├── POST /v1/detect
  │     ├── POST /v1/decide
  │     └── POST /v1/verify
  │
  └── audit log
        ↓
     S3 Object Lock / DynamoDB append-only
        ↓
     Athena / CloudWatch metric
        ↓
     Grafana evidence panel
```

### Vai trò từng service

| Service | Vai trò |
|---|---|
| EKS | Chạy workload, Self-Heal Engine, operator/job xử lý action |
| Prometheus / AMP | Lưu metrics |
| CloudWatch Logs | Lưu logs từ pod/app/AWS |
| Alertmanager / CloudWatch Alarm | Bắn alert khi có sự cố |
| Self-Heal Engine | Detect, decide, execute, verify, rollback/escalate |
| S3 Object Lock / DynamoDB | Lưu audit trail chống sửa/xóa |
| Amazon Managed Grafana | Dashboard cloud-managed để xem toàn bộ flow |

---

## 4. Cấu hình Grafana như thế nào?

Có 2 cách.

---

## Cách A — Tự cài Grafana trong EKS

Phù hợp nếu team muốn nhanh, local demo, ít phụ thuộc AWS managed service.

Cài bằng Helm:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring
```

Mở Grafana:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Truy cập:

```text
http://localhost:3000
```

Ưu điểm:

- Nhanh.
- Dễ demo trong sandbox.
- Có sẵn Prometheus, Alertmanager, dashboard K8s cơ bản.

Nhược điểm:

- Team phải tự vận hành Grafana.
- Nếu pod Grafana lỗi thì dashboard mất.
- Ít “cloud-native story” hơn Amazon Managed Grafana.

---

## Cách B — Dùng Amazon Managed Grafana

Đây là hướng nên cân nhắc cho TF3 nếu muốn triển khai “đúng cloud” hơn.

**Amazon Managed Grafana** là dịch vụ Grafana do AWS quản lý. Team không cần tự vận hành server Grafana. AWS lo provisioning, setup, scaling, maintenance của Grafana workspace.

Luồng tích hợp đề xuất:

```text
EKS workload + Self-Heal Engine
  ↓ expose /metrics
Amazon Managed Service for Prometheus
  ↓ data source
Amazon Managed Grafana
  ↓ dashboard
CDO/mentor xem dashboard
```

Nếu cần logs:

```text
EKS pod logs
  ↓
CloudWatch Logs
  ↓ data source
Amazon Managed Grafana
```

Các bước cấu hình ngắn gọn:

1. **Tạo Amazon Managed Service for Prometheus workspace**
   - Dùng để lưu metrics từ EKS.

2. **Gửi metrics từ EKS lên AMP**
   - Dùng Prometheus remote_write hoặc AWS Distro for OpenTelemetry Collector.
   - Self-Heal Engine cần expose endpoint `/metrics`.

3. **Tạo Amazon Managed Grafana workspace**
   - Chọn authentication bằng IAM Identity Center hoặc SAML.
   - Với capstone, IAM Identity Center thường dễ quản lý hơn.

4. **Enable data source**
   - Add **Amazon Managed Service for Prometheus** làm data source.
   - Add **CloudWatch** nếu muốn xem AWS metrics/logs.

5. **Import dashboard**
   - Tạo dashboard TF3.
   - Panel chính:
     - Auto-resolve rate
     - Scenario injected
     - Unsafe action blocked
     - Rollback count
     - Escalation count
     - API latency/error rate
     - Audit write success/failure

---

## 5. Metrics nên expose từ Self-Heal Engine

Self-Heal Engine nên expose các metric này ở `/metrics`:

```text
selfheal_scenarios_total{tenant,pattern}
selfheal_auto_resolved_total{tenant,pattern}
selfheal_action_total{tenant,pattern,action,result}
selfheal_verify_total{tenant,pattern,result}
selfheal_rollback_total{tenant,pattern}
selfheal_escalation_total{tenant,pattern}
selfheal_unsafe_action_blocked_total{tenant,reason}
http_requests_total{route,status}
http_request_duration_seconds_bucket{route}
```

Ví dụ panel quan trọng nhất: **Auto-resolve rate**

```promql
sum(increase(selfheal_auto_resolved_total[4h]))
/
sum(increase(selfheal_scenarios_total[4h]))
```

Ví dụ panel: **Unsafe action**

```promql
sum(increase(selfheal_unsafe_action_blocked_total[4h]))
```

Với TF3, giá trị này nên là **0 unsafe action thực thi**. Nếu có unsafe action bị block thì phải show là hệ thống đã chặn, không execute.

---

## 6. Dashboard tối thiểu nên có

Chỉ cần 1 dashboard chính tên:

```text
TF3 Self-Heal Engine Overview
```

Panel nên có:

| Panel | Ý nghĩa |
|---|---|
| Total scenarios | Đã inject bao nhiêu scenario |
| Auto-resolve rate | Tỷ lệ tự xử lý thành công |
| Known patterns | OOMKilled, service stuck, queue backlog... |
| Unsafe action blocked | Safety guard có hoạt động không |
| Rollback count | Có rollback khi verify fail không |
| Escalation count | Bao nhiêu case phải gọi người |
| API latency | `/detect`, `/decide`, `/verify` có chậm không |
| Audit write status | Action có được ghi audit không |

---

## 7. Kết luận nên dùng gì cho TF3?

Khuyến nghị:

```text
EKS
+ Amazon Managed Service for Prometheus
+ Amazon Managed Grafana
+ CloudWatch Logs
+ S3 Object Lock hoặc DynamoDB append-only audit
```

Lý do:

- Hợp với đề bài Kubernetes/EKS.
- Ít tốn công vận hành Grafana.
- Dễ defend với panel vì dùng managed observability của AWS.
- Dashboard trở thành evidence cho requirement TF3.
- Có thể show rõ end-to-end flow: alert → detect → decide → execute → verify → audit → dashboard.


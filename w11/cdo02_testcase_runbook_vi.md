# TF3 · CDO-02 - Tổng hợp Test Case & Thứ tự chạy

**File:** `cdo02_testcase_runbook_vi.md`  
**Team:** CDO-02  
**Task Force:** TF3 - Self-Heal Engine  
**Solution angle:** K8s-heavy / Kubernetes Workflow Orchestration  
**Mục đích:** Tổng hợp các test case cần chạy, thứ tự chạy, step thực hiện và evidence cần lưu để hoàn thiện `07_test_eval_report.md`.

---

## 1. Mục tiêu của bộ test

Bộ test này dùng để chứng minh solution của CDO-02 đáp ứng yêu cầu TF3:

```text
detect -> match runbook -> execute audited action -> verify -> escalate nếu fail
```

Các mục tiêu cần chứng minh:

1. CDO executor gọi đúng AI contract: `/v1/detect`, `/v1/decide`, `/v1/verify`.
2. Safety gate chặn được unsafe action.
3. Có multi-tenant isolation giữa `tenant-a` và `tenant-b`.
4. Có audit log theo `correlation_id`.
5. Có ít nhất `>=10 scenarios` được injected.
6. Có scenario simulation window `>=4h`.
7. Auto-resolve rate đạt `>=60%`.
8. Unsafe action count bằng `0`.
9. Khi AI lỗi, timeout hoặc confidence thấp thì hệ thống không execute bừa mà escalate + audit.
10. Có evidence rõ ràng để đưa vào `07_test_eval_report.md`.

---

## 2. Cấu trúc môi trường test đề xuất

### 2.1 Namespace

```text
platform   -> chạy CDO executor, telemetry collector/preprocessor
tenant-a   -> sample workload tenant A
tenant-b   -> sample workload tenant B
```

### 2.2 Thành phần cần có trước khi chạy test

| Thành phần | Bắt buộc? | Ghi chú |
|---|---|---|
| Kubernetes/EKS sandbox | Có | Có thể dùng EKS thật hoặc K8s sandbox nếu trainer chấp nhận |
| Namespace `platform`, `tenant-a`, `tenant-b` | Có | Dùng để chứng minh multi-tenant |
| CDO Self-Heal Executor | Có | Thành phần chính cần test |
| Telemetry preprocessor | Có | Đọc RE2/RE3 dataset hoặc nhận synthetic telemetry |
| AI skeleton/real endpoint | Có | Từ AI team; ban đầu có thể dùng skeleton |
| Audit storage | Có | S3 Object Lock hoặc append-only fallback |
| Observability | Nên có | CloudWatch/Prometheus/logs để lấy evidence |
| Test scripts | Nên có | `tests/contract`, `tests/e2e`, `tests/security`, `tests/load` |

---

## 3. Thứ tự chạy test khuyến nghị

Không nên chạy E2E ngay từ đầu. Nên chạy theo thứ tự dưới đây để dễ debug:

```text
Phase 0 - Pre-check môi trường
Phase 1 - Contract test với AI endpoint
Phase 2 - Telemetry preprocessing test
Phase 3 - Safety gate unit/integration test
Phase 4 - RBAC & multi-tenant isolation test
Phase 5 - E2E happy path self-heal
Phase 6 - E2E negative/failure scenarios
Phase 7 - Audit evidence test
Phase 8 - Load test nhẹ
Phase 9 - Chaos/failure test
Phase 10 - Tổng hợp kết quả vào 07_test_eval_report.md
```

Lý do chạy theo thứ tự này:

- Nếu AI contract chưa gọi được thì E2E sẽ fail.
- Nếu telemetry sai schema thì AI detect/decide không đáng tin.
- Nếu safety gate chưa pass unit test thì không nên cho execute thật trên Kubernetes.
- Nếu RBAC sai thì có thể gây unsafe action hoặc bị panel hỏi sâu.
- Sau khi các lớp nền ổn mới chạy E2E, load và chaos.

---

# PHASE 0 - Pre-check môi trường

## TC-00.1 - Kiểm tra namespace tồn tại

### Mục tiêu

Đảm bảo môi trường test có đủ namespace theo thiết kế CDO-02.

### Steps

```bash
kubectl get ns platform
kubectl get ns tenant-a
kubectl get ns tenant-b
```

### Expected result

```text
platform   Active
tenant-a   Active
tenant-b   Active
```

### Evidence cần lưu

```text
evidence/precheck/namespaces.txt
```

---

## TC-00.2 - Kiểm tra CDO executor đang chạy

### Mục tiêu

Đảm bảo executor trong namespace `platform` sẵn sàng xử lý workflow.

### Steps

```bash
kubectl get pods -n platform
kubectl get deploy -n platform
kubectl logs -n platform deploy/cdo-self-heal-executor --tail=100
```

### Expected result

```text
Pod executor ở trạng thái Running/Ready.
Log không có lỗi startup nghiêm trọng.
```

### Evidence cần lưu

```text
evidence/precheck/executor-pods.txt
evidence/precheck/executor-startup-logs.txt
```

---

## TC-00.3 - Kiểm tra sample workload của tenant

### Mục tiêu

Đảm bảo `tenant-a` và `tenant-b` có workload để restart/scale/dry-run patch.

### Steps

```bash
kubectl get deploy -n tenant-a
kubectl get deploy -n tenant-b
kubectl get pods -n tenant-a
kubectl get pods -n tenant-b
```

### Expected result

```text
Mỗi tenant có ít nhất 1 deployment sample.
Pod ở trạng thái Running.
```

### Evidence cần lưu

```text
evidence/precheck/tenant-workloads.txt
```

---

# PHASE 1 - Contract test với AI endpoint

## TC-01.1 - Gọi `/v1/detect` thành công

### Mục tiêu

Kiểm tra CDO gọi được endpoint detect của AI theo contract.

### Input mẫu

```json
{
  "telemetry_window": [
    {
      "ts": "2026-06-25T10:00:00.123Z",
      "signal_name": "istio_request_error_rate",
      "value": 0.45,
      "labels": {
        "service": "adservice",
        "tenant_id": "cdo-2"
      }
    }
  ]
}
```

### Steps

```bash
curl -X POST "$AI_ENDPOINT/v1/detect" \
  -H "X-Tenant-Id: cdo-2" \
  -H "X-Correlation-Id: test-detect-001" \
  -H "Content-Type: application/json" \
  -d @tests/payloads/detect-error-rate.json
```

### Expected result

Response có các field:

```text
anomaly_detected
severity
anomaly_context
confidence
correlation_id
```

### Evidence cần lưu

```text
evidence/contract/detect-response.json
```

---

## TC-01.2 - Gọi `/v1/decide` thành công

### Mục tiêu

Kiểm tra AI trả về `action_plan` để CDO safety gate xử lý.

### Steps

```bash
curl -X POST "$AI_ENDPOINT/v1/decide" \
  -H "X-Tenant-Id: cdo-2" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Content-Type: application/json" \
  -d @tests/payloads/decide-service-stuck.json
```

### Expected result

Response có:

```text
matched_runbook
action_plan[]
blast_radius_config
```

Action chỉ thuộc allow-list:

```text
RESTART_DEPLOYMENT
SCALE_UP_PODS
UPDATE_ENV_SECRET
ADJUST_MEMORY_LIMIT
```

### Evidence cần lưu

```text
evidence/contract/decide-response.json
```

---

## TC-01.3 - Gọi `/v1/verify` thành công

### Mục tiêu

Kiểm tra CDO có thể gửi post-action telemetry để AI xác nhận incident đã resolved hay chưa.

### Steps

```bash
curl -X POST "$AI_ENDPOINT/v1/verify" \
  -H "X-Tenant-Id: cdo-2" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Content-Type: application/json" \
  -d @tests/payloads/verify-success.json
```

### Expected result

Response có:

```text
success
regression_detected
next_action
```

`next_action` thuộc một trong các giá trị:

```text
DONE
RETRY
ROLLBACK
ESCALATE
```

### Evidence cần lưu

```text
evidence/contract/verify-response.json
```

---

## TC-01.4 - Test error code `400`

### Mục tiêu

Kiểm tra khi gửi sai schema, CDO/AI không retry bừa.

### Steps

Gửi payload thiếu `telemetry_window`.

```bash
curl -X POST "$AI_ENDPOINT/v1/detect" \
  -H "X-Tenant-Id: cdo-2" \
  -H "Content-Type: application/json" \
  -d '{}'
```

### Expected result

```text
HTTP 400.
CDO log lỗi schema.
Không retry tự động.
Không execute action.
```

### Evidence cần lưu

```text
evidence/contract/bad-request-400.txt
```

---

## TC-01.5 - Test error code `429`

### Mục tiêu

Kiểm tra CDO xử lý rate limit bằng exponential backoff.

### Steps

Gửi nhiều request liên tục vượt rate limit hoặc dùng mock endpoint trả `429`.

```bash
for i in {1..150}; do
  curl -s -o /dev/null -w "%{http_code}\n" "$AI_ENDPOINT/v1/detect" &
done
wait
```

### Expected result

```text
CDO không crash.
Có retry/backoff.
Không execute trùng action.
```

### Evidence cần lưu

```text
evidence/contract/rate-limit-429.txt
evidence/contract/executor-backoff-logs.txt
```

---

## TC-01.6 - Test error code `503`

### Mục tiêu

Kiểm tra khi AI unavailable, CDO fail-safe.

### Steps

Dùng mock endpoint trả `503` hoặc tạm trỏ AI endpoint sang URL lỗi.

```bash
export AI_ENDPOINT=http://mock-ai-503.local
```

Inject một scenario bình thường.

### Expected result

```text
CDO không execute Kubernetes action.
CDO tạo escalation.
CDO ghi audit reason = ai_unavailable hoặc ai_503.
```

### Evidence cần lưu

```text
evidence/contract/ai-503-fallback.txt
evidence/audit/ai-503-audit.json
```

---

# PHASE 2 - Telemetry preprocessing test

## TC-02.1 - Inject `tenant_id` cho RE2 dataset

### Mục tiêu

Kiểm tra preprocessor tự inject tenant ID khi dữ liệu gốc không có tenant.

### Steps

```bash
python scripts/preprocess_re_dataset.py \
  --dataset RE2 \
  --input data/re2/metrics.csv \
  --output reports/re2-normalized.jsonl
```

### Expected result

Mỗi record output có:

```json
"tenant_id": "tnt-re2-simulation"
```

### Evidence cần lưu

```text
reports/re2-normalized.jsonl
evidence/telemetry/re2-tenant-id-check.txt
```

Có thể kiểm tra nhanh:

```bash
grep -v "tnt-re2-simulation" reports/re2-normalized.jsonl
```

Expected: không có dòng nào thiếu tenant.

---

## TC-02.2 - Inject `tenant_id` cho RE3 dataset

### Steps

```bash
python scripts/preprocess_re_dataset.py \
  --dataset RE3 \
  --input data/re3/metrics.csv \
  --output reports/re3-normalized.jsonl
```

### Expected result

Mỗi record output có:

```json
"tenant_id": "tnt-re3-simulation"
```

### Evidence cần lưu

```text
reports/re3-normalized.jsonl
evidence/telemetry/re3-tenant-id-check.txt
```

---

## TC-02.3 - Tính `istio_request_error_rate`

### Mục tiêu

Kiểm tra preprocessor tính error rate từ counter đúng công thức.

### Steps

Chạy preprocessor trên metrics có:

```text
<service>_istio-error-total
<service>_istio-request-total
```

Sau đó kiểm tra output signal:

```bash
grep "istio_request_error_rate" reports/re3-normalized.jsonl | head
```

### Expected result

Output có signal:

```json
{
  "signal_name": "istio_request_error_rate",
  "value": 0.0_to_1.0
}
```

### Evidence cần lưu

```text
evidence/telemetry/error-rate-output.txt
```

---

## TC-02.4 - Parse `app_log_error_event`

### Mục tiêu

Kiểm tra log parser lấy đúng ERROR/stack trace để gửi sang AI.

### Steps

```bash
python scripts/preprocess_logs.py \
  --input data/re3/logs.csv \
  --output reports/log-error-events.jsonl

grep "app_log_error_event" reports/log-error-events.jsonl | head
```

### Expected result

Record có:

```text
service
pod_name
level=ERROR
message
tenant_id
```

### Evidence cần lưu

```text
reports/log-error-events.jsonl
evidence/telemetry/log-error-event-sample.txt
```

---

## TC-02.5 - Parse `trace_span_error_event`

### Mục tiêu

Kiểm tra trace parser lấy đúng span lỗi.

### Steps

```bash
python scripts/preprocess_traces.py \
  --input data/re2/traces.csv \
  --output reports/trace-error-events.jsonl

grep "trace_span_error_event" reports/trace-error-events.jsonl | head
```

### Expected result

Record có:

```text
trace_id
span_id
operation
status_code != 0
tenant_id
```

### Evidence cần lưu

```text
reports/trace-error-events.jsonl
evidence/telemetry/trace-error-event-sample.txt
```

---

# PHASE 3 - Safety gate test

## TC-03.1 - Allow action hợp lệ `RESTART_DEPLOYMENT`

### Mục tiêu

Kiểm tra safety gate cho phép action hợp lệ cùng tenant.

### Input

```json
{
  "tenant_id": "tenant-a",
  "action": "RESTART_DEPLOYMENT",
  "target": "deployment/adservice",
  "namespace": "tenant-a"
}
```

### Steps

```bash
python tests/safety/test_safety_gate.py --case allow-restart-same-tenant
```

### Expected result

```text
safety_decision = PASS
reason = allowed
```

### Evidence

```text
evidence/safety/allow-restart-same-tenant.txt
```

---

## TC-03.2 - Deny cross-tenant action

### Mục tiêu

Kiểm tra incident tenant-a không được thao tác namespace tenant-b.

### Input

```json
{
  "tenant_id": "tenant-a",
  "action": "RESTART_DEPLOYMENT",
  "target": "deployment/adservice",
  "namespace": "tenant-b"
}
```

### Steps

```bash
python tests/safety/test_safety_gate.py --case deny-cross-tenant
```

### Expected result

```text
safety_decision = DENY
reason = denied_cross_tenant
Không gọi Kubernetes API.
Có audit record.
```

### Evidence

```text
evidence/safety/deny-cross-tenant.txt
evidence/audit/deny-cross-tenant-audit.json
```

---

## TC-03.3 - Deny unsupported action

### Mục tiêu

Kiểm tra nếu AI trả action ngoài allow-list thì CDO chặn.

### Input

```json
{
  "tenant_id": "tenant-a",
  "action": "DELETE_NAMESPACE",
  "target": "namespace/tenant-a",
  "namespace": "tenant-a"
}
```

### Steps

```bash
python tests/safety/test_safety_gate.py --case deny-unsupported-action
```

### Expected result

```text
safety_decision = DENY
reason = unsupported_action
Không execute.
```

### Evidence

```text
evidence/safety/deny-unsupported-action.txt
```

---

## TC-03.4 - Deny vượt blast-radius

### Mục tiêu

Kiểm tra nếu action restart/scale vượt giới hạn ảnh hưởng thì CDO chặn.

### Steps

```bash
python tests/safety/test_safety_gate.py --case deny-blast-radius
```

### Expected result

```text
safety_decision = DENY
reason = blast_radius_exceeded
```

### Evidence

```text
evidence/safety/deny-blast-radius.txt
```

---

## TC-03.5 - Deny duplicate idempotency key

### Mục tiêu

Kiểm tra cùng một action không bị execute hai lần.

### Steps

```bash
export IDEMPOTENCY_KEY="11111111-1111-4111-8111-111111111111"

python tests/e2e/inject_scenario.py --scenario SH-001 --idempotency-key $IDEMPOTENCY_KEY
python tests/e2e/inject_scenario.py --scenario SH-001 --idempotency-key $IDEMPOTENCY_KEY
```

### Expected result

```text
Lần 1: execute/mock execute.
Lần 2: denied_duplicate hoặc HTTP 409.
Không có action thứ hai trên Kubernetes.
```

### Evidence

```text
evidence/safety/idempotency-duplicate.txt
evidence/audit/idempotency-duplicate-audit.json
```

---

## TC-03.6 - Escalate khi confidence thấp

### Mục tiêu

Kiểm tra nếu AI trả confidence thấp thì CDO không execute.

### Steps

Dùng mock `/v1/decide` trả:

```json
{
  "confidence": 0.40,
  "action_plan": [
    {
      "action": "RESTART_DEPLOYMENT",
      "target": "deployment/adservice",
      "params": {
        "namespace": "tenant-a"
      }
    }
  ]
}
```

Sau đó inject scenario.

### Expected result

```text
CDO không execute.
CDO escalate.
Audit reason = low_confidence.
```

### Evidence

```text
evidence/safety/low-confidence-escalation.txt
```

---

# PHASE 4 - RBAC & Multi-tenant isolation test

## TC-04.1 - Executor không có cluster-admin

### Steps

```bash
kubectl auth can-i '*' '*' \
  --as=system:serviceaccount:platform:cdo-executor
```

### Expected result

```text
no
```

### Evidence

```text
evidence/rbac/executor-not-cluster-admin.txt
```

---

## TC-04.2 - Executor không được delete namespace

### Steps

```bash
kubectl auth can-i delete namespace \
  --as=system:serviceaccount:platform:cdo-executor
```

### Expected result

```text
no
```

### Evidence

```text
evidence/rbac/executor-cannot-delete-namespace.txt
```

---

## TC-04.3 - Executor được patch deployment trong namespace được phép

### Steps

```bash
kubectl auth can-i patch deployment -n tenant-a \
  --as=system:serviceaccount:platform:cdo-executor

kubectl auth can-i patch deployment -n tenant-b \
  --as=system:serviceaccount:platform:cdo-executor
```

### Expected result

Tùy mô hình RBAC nhóm chọn:

```text
Nếu executor platform là executor chung: yes cho tenant-a và tenant-b, nhưng safety gate kiểm soát tenant.
Nếu executor tách per tenant: chỉ yes với namespace được bind.
```

### Evidence

```text
evidence/rbac/executor-patch-deployment.txt
```

---

## TC-04.4 - Tenant A không được mutate Tenant B

### Mục tiêu

Nếu team có service account riêng theo tenant, test tenant-a không patch được tenant-b.

### Steps

```bash
kubectl auth can-i patch deployment -n tenant-b \
  --as=system:serviceaccount:tenant-a:tenant-a-executor
```

### Expected result

```text
no
```

### Evidence

```text
evidence/rbac/tenant-a-cannot-mutate-tenant-b.txt
```

---

## TC-04.5 - Cross-tenant scenario phải bị audit

### Steps

```bash
python tests/e2e/inject_scenario.py --scenario SH-011-cross-tenant
```

### Expected result

```text
Kubernetes deployment không thay đổi.
Audit có:
- tenant_id = tenant-a
- target_namespace = tenant-b
- decision = DENY
- reason = denied_cross_tenant
```

### Evidence

```text
evidence/audit/cross-tenant-deny.json
```

---

# PHASE 5 - E2E happy path self-heal

## TC-05.1 - E2E restart deployment cho service stuck

### Mục tiêu

Chứng minh luồng chính chạy end-to-end.

### Scenario

```text
Tenant: tenant-a
Pattern: Service stuck / latency spike
Signal: istio_request_latency_p95 high
Expected action: RESTART_DEPLOYMENT
```

### Steps

```bash
python tests/e2e/inject_scenario.py --scenario SH-001
```

Theo dõi log:

```bash
kubectl logs -n platform deploy/cdo-self-heal-executor -f
```

Kiểm tra rollout:

```bash
kubectl rollout status deployment/adservice -n tenant-a
kubectl get pods -n tenant-a
```

### Expected result

```text
detect_called
decide_called
safety_passed
dry_run_done
execute_done hoặc mock_execute_done
verify_called
verify_done success=true
audit query được theo correlation_id
```

### Evidence

```text
reports/scenario-results.csv
evidence/e2e/SH-001-executor-log.txt
evidence/e2e/SH-001-kubectl-rollout.txt
evidence/audit/SH-001-audit.json
```

---

## TC-05.2 - E2E restart deployment cho error rate spike

### Scenario

```text
Tenant: tenant-b
Pattern: Error rate spike
Signal: istio_request_error_rate high
Expected action: RESTART_DEPLOYMENT hoặc safe escalation
```

### Steps

```bash
python tests/e2e/inject_scenario.py --scenario SH-003
```

### Expected result

```text
Nếu action an toàn:
- safety_passed
- execute/mock_execute
- verify success

Nếu action không đủ context:
- no execute
- escalation_bundle generated
- audit reason rõ ràng
```

### Evidence

```text
evidence/e2e/SH-003-result.txt
evidence/audit/SH-003-audit.json
```

---

## TC-05.3 - E2E memory pressure / OOM prevention

### Scenario

```text
Tenant: tenant-a
Pattern: Memory pressure
Signal: container_memory_working_set_bytes high
Expected action: ADJUST_MEMORY_LIMIT
```

### Steps

Nếu patch thật quá rủi ro, chạy dry-run:

```bash
python tests/e2e/inject_scenario.py --scenario SH-005 --dry-run
```

Hoặc nếu có sandbox an toàn:

```bash
kubectl patch deployment emailservice -n tenant-a \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"}]' \
  --dry-run=server -o yaml
```

### Expected result

```text
dry_run_done
Không vượt blast-radius
verify_called
Nếu chưa đủ bằng chứng an toàn thì escalate thay vì patch thật
```

### Evidence

```text
evidence/e2e/SH-005-memory-dry-run.txt
evidence/audit/SH-005-audit.json
```

---

## TC-05.4 - RE2 Offline Simulation Mode

### Mục tiêu

Chứng minh CDO xử lý dataset RE2 theo contract simulation.

### Steps

```bash
python tests/e2e/run_offline_simulation.py \
  --dataset RE2 \
  --window 4h \
  --output reports/re2-simulation-results.csv
```

### Expected result

```text
tenant_id = tnt-re2-simulation
mock_execute_done
post_telemetry_window gửi sang /v1/verify
có kết quả success/regression/next_action
```

### Evidence

```text
reports/re2-simulation-results.csv
evidence/e2e/re2-simulation-log.txt
```

---

## TC-05.5 - RE3 Offline Simulation Mode

### Steps

```bash
python tests/e2e/run_offline_simulation.py \
  --dataset RE3 \
  --window 4h \
  --output reports/re3-simulation-results.csv
```

### Expected result

```text
tenant_id = tnt-re3-simulation
mock_execute_done
post_telemetry_window gửi sang /v1/verify
có kết quả success/regression/next_action
```

### Evidence

```text
reports/re3-simulation-results.csv
evidence/e2e/re3-simulation-log.txt
```

---

# PHASE 6 - Negative/failure scenarios

## TC-06.1 - AI trả unsupported action

### Steps

Mock `/v1/decide` trả:

```json
{
  "action_plan": [
    {
      "action": "DELETE_NAMESPACE",
      "target": "namespace/tenant-a",
      "params": {
        "namespace": "tenant-a"
      }
    }
  ]
}
```

Inject scenario:

```bash
python tests/e2e/inject_scenario.py --scenario SH-013
```

### Expected result

```text
Safety deny.
Không gọi Kubernetes mutate.
Audit reason = unsupported_action.
```

### Evidence

```text
evidence/negative/unsupported-action-deny.txt
```

---

## TC-06.2 - AI timeout

### Steps

Dùng mock endpoint delay quá timeout.

```bash
python tests/e2e/inject_scenario.py --scenario SH-014-ai-timeout
```

### Expected result

```text
No execute.
Escalate.
Audit reason = ai_timeout.
```

### Evidence

```text
evidence/negative/ai-timeout-escalation.txt
```

---

## TC-06.3 - Verify regression

### Steps

Mock `/v1/verify` trả:

```json
{
  "success": false,
  "regression_detected": true,
  "next_action": "ROLLBACK"
}
```

Inject scenario:

```bash
python tests/e2e/inject_scenario.py --scenario SH-015-verify-regression
```

### Expected result

```text
CDO rollback nếu rollback plan safe.
Nếu không rollback được thì escalate.
Audit có verify_result và rollback/escalation result.
```

### Evidence

```text
evidence/negative/verify-regression-rollback.txt
```

---

## TC-06.4 - Audit write fail

### Mục tiêu

Kiểm tra nếu không ghi audit được thì CDO không nên tiếp tục execute action nguy hiểm.

### Steps

Tạm đổi audit bucket/path sang nơi không có quyền write trong test env.

```bash
export AUDIT_BUCKET=s3://invalid-or-denied-bucket
python tests/e2e/inject_scenario.py --scenario SH-016-audit-fail
```

### Expected result

```text
CDO stop execution hoặc mark unsafe.
Không có Kubernetes mutate action nếu audit pre-action fail.
Log lỗi audit_write_failed.
```

### Evidence

```text
evidence/negative/audit-write-fail.txt
```

---

# PHASE 7 - Audit evidence test

## TC-07.1 - Query audit theo `correlation_id`

### Steps

Lấy correlation ID từ một scenario đã chạy:

```bash
export CID=<correlation-id>
```

Nếu audit ở S3:

```bash
aws s3 ls s3://<audit-bucket>/tenant_id=tenant-a/correlation_id=$CID/
aws s3 cp s3://<audit-bucket>/tenant_id=tenant-a/correlation_id=$CID/audit.json -
```

Nếu dùng local append-only fallback:

```bash
grep "$CID" reports/audit-log.jsonl
```

### Expected result

Có đủ event chain:

```text
alert_received
telemetry_collected
detect_called
detect_response_received
decide_called
action_plan_received
safety_passed/safety_denied
dry_run_done
execute_done/mock_execute_done/denied
verify_called
verify_done
incident_closed/escalated
```

### Evidence

```text
evidence/audit/query-by-correlation-id.txt
evidence/audit/sample-audit-chain.json
```

---

## TC-07.2 - Audit record có đủ field bắt buộc

### Steps

```bash
python tests/audit/validate_audit_schema.py \
  --input evidence/audit/sample-audit-chain.json
```

### Expected result

Mỗi record có:

```text
timestamp
correlation_id
tenant_id
namespace
action_type
decision
result
reason
idempotency_key
```

### Evidence

```text
evidence/audit/audit-schema-validation.txt
```

---

# PHASE 8 - Load test nhẹ

## TC-08.1 - Load test CDO executor workflow

### Mục tiêu

Kiểm tra executor chịu được nhiều workflow request mà không duplicate, không mất audit.

### Steps

```bash
k6 run tests/load/self_heal_workflow.js \
  -e BASE_URL=$EXECUTOR_URL \
  -e TENANT_ID=cdo-2 \
  -e TEST_MODE=mock
```

Profile đề xuất:

```text
Ramp-up: 0 -> 20 workflow/min trong 5 phút
Sustained: 20 workflow/min trong 10 phút
Traffic mix:
- 70% happy path
- 20% denied action
- 10% AI error/fallback
```

### Expected result

```text
p99 executor orchestration latency < 1000ms hoặc target team chốt.
error rate < 1%.
unsafe_action_count = 0.
audit_loss_count = 0.
```

### Evidence

```text
reports/k6-summary.json
reports/k6-summary.txt
evidence/load/executor-load-test.txt
```

---

# PHASE 9 - Chaos/failure test

## TC-09.1 - AI endpoint unavailable trong lúc scenario đang chạy

### Steps

Trong test env, trỏ AI endpoint sang mock 503 hoặc chặn network.

```bash
python tests/chaos/simulate_ai_down.py --duration 60s
python tests/e2e/inject_scenario.py --scenario SH-014-ai-timeout
```

### Expected result

```text
CDO không execute.
CDO escalate.
Audit ghi ai_unavailable.
```

### Evidence

```text
evidence/chaos/ai-down-result.txt
```

---

## TC-09.2 - Circuit breaker khi error rate sau action vẫn cao

### Steps

Mock verify hoặc post-telemetry cho thấy error rate vẫn cao.

```bash
python tests/e2e/inject_scenario.py --scenario SH-017-circuit-breaker
```

### Expected result

```text
CDO không retry vô hạn.
Circuit breaker mở.
Rollback hoặc escalate.
Audit reason = circuit_breaker_open.
```

### Evidence

```text
evidence/chaos/circuit-breaker-result.txt
```

---

## TC-09.3 - Pod executor restart giữa workflow

### Steps

Inject scenario, sau đó restart executor pod trong test env:

```bash
python tests/e2e/inject_scenario.py --scenario SH-001 &
kubectl rollout restart deployment/cdo-self-heal-executor -n platform
```

### Expected result

```text
Không execute trùng nhờ idempotency key.
Workflow recover hoặc escalate an toàn.
Audit không bị mất chain nghiêm trọng.
```

### Evidence

```text
evidence/chaos/executor-restart-result.txt
```

---

# PHASE 10 - Tổng hợp kết quả

## 10.1 Tạo file scenario result

Sau khi chạy tất cả scenario, tạo:

```text
reports/scenario-results.csv
```

Format đề xuất:

```csv
scenario_id,tenant,pattern,action,mode,safety_decision,verify_success,auto_resolved,unsafe_action,audit_found,evidence_link
SH-001,tenant-a,latency_spike,RESTART_DEPLOYMENT,live,PASS,true,true,false,true,evidence/e2e/SH-001
SH-011,tenant-a,cross_tenant,RESTART_DEPLOYMENT,negative,DENY,false,false,false,true,evidence/audit/cross-tenant-deny.json
```

---

## 10.2 Tính auto-resolve rate

Công thức:

```text
auto_resolve_rate = auto_resolved_scenarios / total_injected_scenarios
```

Chỉ tính là auto-resolved khi:

```text
safety_passed = true
AND action completed hoặc mock completed
AND verify_success = true
AND regression_detected = false
AND audit_found = true
```

Không tính safe escalation là auto-resolved, nhưng safe escalation vẫn là hành vi đúng nếu action không an toàn.

---

## 10.3 Bảng kết quả cần đưa vào `07_test_eval_report.md`

| Metric | Target | Actual | Pass/Fail | Evidence |
|---|---:|---:|---|---|
| Total scenarios | >=10 | TBD | TBD | `reports/scenario-results.csv` |
| Simulation window | >=4h | TBD | TBD | `reports/re2/re3-simulation-results.csv` |
| Auto-resolve rate | >=60% | TBD | TBD | `reports/scenario-results.csv` |
| Unsafe action count | 0 | TBD | TBD | Audit query |
| Cross-tenant deny pass | 100% | TBD | TBD | `evidence/audit/cross-tenant-deny.json` |
| Audit query success | 100% sampled incidents | TBD | TBD | `evidence/audit/` |
| Executor p99 latency | <1000ms target | TBD | TBD | `reports/k6-summary.json` |
| AI endpoint contract pass | 100% critical endpoints | TBD | TBD | `evidence/contract/` |
| Trivy critical findings | 0 | TBD | TBD | `security/trivy-executor.json` |

---

# 11. Checklist evidence cuối cùng

Trước khi đóng task Jira/file report, cần có:

```text
reports/scenario-results.csv
reports/k6-summary.json
reports/contract-test-results.json
reports/re2-simulation-results.csv
reports/re3-simulation-results.csv

security/trivy-executor.json

evidence/precheck/
evidence/contract/
evidence/telemetry/
evidence/safety/
evidence/rbac/
evidence/e2e/
evidence/negative/
evidence/audit/
evidence/load/
evidence/chaos/
```

---

# 12. Thứ tự chạy ngắn gọn cho PM/Reviewer

Nếu cần báo cáo ngắn cho PM, dùng thứ tự sau:

```text
1. Pre-check cluster/namespace/executor/workload.
2. Contract test 3 endpoint AI: detect, decide, verify.
3. Telemetry test: RE2/RE3 preprocessing + tenant_id injection.
4. Safety gate test: allow-list, cross-tenant deny, blast-radius, idempotency.
5. RBAC test: executor không cluster-admin, không delete namespace.
6. E2E happy path: restart deployment, error rate spike, memory pressure.
7. Offline simulation: RE2 + RE3 trong >=4h window.
8. Negative test: unsupported action, AI timeout, verify regression, audit write fail.
9. Audit query test theo correlation_id.
10. Load test nhẹ bằng k6/Locust.
11. Chaos test: AI down, circuit breaker, executor restart.
12. Tổng hợp auto-resolve rate, unsafe action count, evidence link vào 07_test_eval_report.md.
```

---

# 13. Gợi ý chia Jira task

| Jira task | Scope | Evidence |
|---|---|---|
| CDO2-TEST-01 | Pre-check + namespace/workload evidence | `evidence/precheck/` |
| CDO2-TEST-02 | AI contract test detect/decide/verify | `evidence/contract/` |
| CDO2-TEST-03 | Telemetry preprocessing RE2/RE3 | `evidence/telemetry/` |
| CDO2-TEST-04 | Safety gate unit/integration tests | `evidence/safety/` |
| CDO2-TEST-05 | RBAC + multi-tenant isolation tests | `evidence/rbac/`, `evidence/audit/` |
| CDO2-TEST-06 | E2E happy path scenarios | `evidence/e2e/`, `reports/scenario-results.csv` |
| CDO2-TEST-07 | Negative/failure scenarios | `evidence/negative/` |
| CDO2-TEST-08 | Audit query + schema validation | `evidence/audit/` |
| CDO2-TEST-09 | Load test + k6 summary | `reports/k6-summary.json` |
| CDO2-TEST-10 | Chaos test + failure analysis | `evidence/chaos/` |
| CDO2-TEST-11 | Fill final `07_test_eval_report.md` | Final markdown report |

---

# 14. Ghi chú quan trọng

1. Không chạy action thật nếu safety gate chưa pass test.
2. Không tính scenario là auto-resolved nếu thiếu audit.
3. Safe escalation là kết quả tốt nếu action không an toàn.
4. Với RE2/RE3 dataset, Mock Mode là hợp lý, nhưng nên bổ sung ít nhất 1-2 live sandbox action để demo thuyết phục.
5. Mọi evidence nên có `correlation_id` để panel hỏi là trace được ngay.
6. Khi test fail, không xóa khỏi report. Ghi vào Failure Analysis: root cause, fix, time to fix.

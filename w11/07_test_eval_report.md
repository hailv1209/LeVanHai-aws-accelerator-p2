# Test & Eval Report - Task Force 3 · CDO-02

**Doc owner:** CDO-02  
**Status:** Draft proposal for W12 Pack #2  
**Last updated:** 2026-06-24  
**Scope:** Self-Heal Engine platform evaluation for CDO-02 K8s-heavy / Kubernetes Workflow Orchestration solution

> Ghi chú: file này là bản đề xuất test plan + report skeleton. Các cột `Measured`, `Evidence`, `Commit/Screenshot` cần được cập nhật sau khi team chạy test thật trong W12.

---

## 1. Purpose

File `07_test_eval_report.md` dùng để chứng minh platform của CDO-02 không chỉ thiết kế đúng, mà đã được kiểm thử bằng evidence rõ ràng.

Với đề TF3 Self-Heal Engine, report này phải trả lời được 6 câu hỏi:

1. Hệ thống có chạy được end-to-end không?
2. CDO executor có consume đúng AI contract không?
3. Safety gate có chặn unsafe action không?
4. Multi-tenant isolation giữa `tenant-a` và `tenant-b` có thật sự hoạt động không?
5. Audit log có đủ để truy vết một incident theo `correlation_id` không?
6. NFR của đề có đạt không: `>=10 scenarios`, `>=60% auto-resolve rate`, `>=4h simulation window`, `0 unsafe action`.

---

## 2. System Under Test

CDO-02 test các thành phần sau:

| Component | Responsibility | Test focus |
|---|---|---|
| Scenario Injector / Alert Source | Tạo incident giả lập hoặc đọc RE2/RE3 dataset | Inject đúng scenario, có `correlation_id` |
| Telemetry Preprocessor | Đọc `metrics.csv`, `logs.csv`, `traces.csv`, inject `tenant_id`, chuẩn hóa signal | Schema, timestamp, tenant scope, PII redaction |
| SQS Telemetry Queue | Buffer telemetry normalized | Message format, retry, dead-letter behavior |
| CDO Self-Heal Executor | Điều phối detect -> decide -> safety -> execute -> verify | Main E2E workflow |
| Safety Gate | Validate tenant, namespace, allow-list, blast-radius, rollback, verify, idempotency | Zero unsafe action |
| Kubernetes Sandbox | `platform`, `tenant-a`, `tenant-b` namespaces + sample workloads | RBAC isolation, real action demo |
| AI Engine Endpoint | `/v1/detect`, `/v1/decide`, `/v1/verify` | Contract integration, latency, error handling |
| Audit Storage | S3 Object Lock or append-only audit store | Tamper-evident log, query by `correlation_id` |
| Observability Stack | CloudWatch/Prometheus-compatible metrics/OTel if available | Logs, metrics, traces for evidence |

---

## 3. Test Coverage

| Test type | Tool / Method | Coverage / Scope | Evidence expected |
|---|---|---|---|
| Unit test | `pytest` / language-native test runner | Safety gate rules, schema validation, runbook mapping, idempotency helper | Test output + CI screenshot |
| Contract test | `curl`, Postman/Newman, JSON schema validator | `/v1/detect`, `/v1/decide`, `/v1/verify`, required headers, error codes | Request/response logs |
| Integration test | Custom test runner | Telemetry preprocessor -> SQS -> executor -> AI skeleton/real endpoint | Logs by `correlation_id` |
| E2E simulation test | Scenario injector + RE2/RE3 dataset | >=10 injected scenarios, >=4h simulated window | Scenario result table |
| Live sandbox test | Kubernetes manifests + executor action | At least 2-3 real K8s actions: restart/scale/dry-run patch | `kubectl` output + audit |
| Security test | Manual + `kubectl auth can-i` + Trivy | RBAC, cross-tenant deny, secret exposure, image scan | Screenshots + scan JSON |
| Load test | k6 / Locust | Sustained workflow calls to executor and AI endpoints | p95/p99, error rate |
| Failure/chaos test | Manual failure injection | AI timeout/503, duplicate idempotency key, audit write fail | Failure analysis table |

---

## 4. Acceptance Criteria

| Requirement | Target | How CDO-02 will prove it | Status |
|---|---:|---|---|
| Known patterns implemented | >=3 patterns | E2E test for `RESTART_DEPLOYMENT`, error spike handling, memory pressure handling | TBD |
| Designed-only patterns | >=2 patterns | Paper playbook + test stub for queue/backpressure and secret/cert/config | TBD |
| Auto-resolve rate | >=60% | `auto_resolved / total_scenarios` over >=10 scenarios | TBD |
| Scenario simulation window | >=4h | Dataset timestamps or scenario runner duration evidence | TBD |
| Unsafe action | 0 | Safety deny tests + audit reason check | TBD |
| Multi-tenant isolation | >=2 tenants | `tenant-a`, `tenant-b`, `platform` namespace tests | TBD |
| Audit retention | >=90 days target | S3 Object Lock config or append-only retention evidence | TBD |
| Safety checkpoints | dry-run, blast-radius, verify, rollback, circuit breaker | Safety gate test cases + audit records | TBD |
| AI integration | Real endpoint by W12 T3 | Calls to `/v1/detect`, `/v1/decide`, `/v1/verify` | TBD |

---

## 5. Test Environment

| Item | Planned value |
|---|---|
| AWS Region | `us-east-1` unless trainer changes |
| Cluster | EKS or Kubernetes sandbox compatible with CDO-02 manifests |
| Namespaces | `platform`, `tenant-a`, `tenant-b` |
| AI tenant ID | `cdo-2` |
| Simulation tenant IDs | `tnt-re2-simulation`, `tnt-re3-simulation` |
| AI endpoint | `https://ai-engine.tf-3.internal/` or temporary skeleton endpoint |
| Auth | IAM SigV4 or agreed temporary token in sandbox |
| Audit | S3 Object Lock target; local append-only fallback only if trainer accepts |
| Observability | CloudWatch Logs + Prometheus-compatible metrics; OTel traces if time permits |

---

## 6. Scenario Set

CDO-02 should run at least 12 scenarios: 8 positive/expected scenarios and 4 negative/safety scenarios. This gives buffer above the hard requirement of >=10 scenarios.

| ID | Tenant | Pattern / Failure | Input signal | Expected action | Expected result | Type |
|---|---|---|---|---|---|---|
| SH-001 | tenant-a | Service stuck / latency spike | `istio_request_latency_p95` high | `RESTART_DEPLOYMENT` | Execute or mock execute, verify success | Build-real |
| SH-002 | tenant-b | Service stuck / latency spike | `istio_request_latency_p95` high | `RESTART_DEPLOYMENT` | Execute or mock execute, verify success | Build-real |
| SH-003 | tenant-a | Error rate spike | `istio_request_error_rate` high | `RESTART_DEPLOYMENT` or escalate | Verify error rate drops or escalate | Build-real |
| SH-004 | tenant-b | Code-level fault | `app_log_error_event` + trace error | `RESTART_DEPLOYMENT` or escalate | Escalation bundle if not safely resolvable | Build-real |
| SH-005 | tenant-a | Memory pressure | `container_memory_working_set_bytes` high | `ADJUST_MEMORY_LIMIT` dry-run/patch | Verify memory pressure resolved or escalate | Build-real |
| SH-006 | tenant-b | Memory pressure | `container_memory_working_set_bytes` high | `ADJUST_MEMORY_LIMIT` dry-run/patch | Verify memory pressure resolved or escalate | Build-real |
| SH-007 | tnt-re2-simulation | RE2 offline scenario | `metrics.csv`, `logs.csv`, `traces.csv` | Mock action | `/v1/verify` with `post_telemetry_window` | Simulation |
| SH-008 | tnt-re3-simulation | RE3 offline scenario | `metrics.csv`, `logs.csv`, `traces.csv` | Mock action | `/v1/verify` with `post_telemetry_window` | Simulation |
| SH-009 | tenant-a | Queue/backpressure | Queue/backlog metric or synthetic signal | `SCALE_UP_PODS` | Design-only or controlled dry-run | Design-only |
| SH-010 | tenant-b | Secret/cert/config issue | Synthetic event | `UPDATE_ENV_SECRET` | Deny or design-only due high risk | Design-only |
| SH-011 | tenant-a -> tenant-b | Cross-tenant target mismatch | AI returns target namespace `tenant-b` for tenant-a incident | None | Safety deny + audit `denied_cross_tenant` | Negative |
| SH-012 | tenant-a | Duplicate execution | Same `Idempotency-Key` twice | None on second request | Second request denied as duplicate | Negative |
| SH-013 | tenant-a | Unsupported action | AI returns action outside allow-list | None | Safety deny + audit `unsupported_action` | Negative |
| SH-014 | tenant-a | AI timeout/503 | Simulated AI unavailable | None or static safe escalation | Escalate + audit, no unsafe execute | Negative |

---

## 7. E2E Test Flow

Each scenario must produce one `correlation_id` and follow this evidence chain:

```text
1. scenario_injected
2. telemetry_collected
3. detect_called
4. detect_response_received
5. decide_called
6. action_plan_received
7. idempotency_lock_acquired or duplicate_denied
8. safety_passed or safety_denied
9. dry_run_done
10. execute_done or mock_execute_done or denied
11. verify_called
12. verify_done
13. rollback_done / escalated / incident_closed
```

A scenario is counted as **auto-resolved** only when:

```text
safety_passed = true
AND action status = COMPLETED or MOCK_COMPLETED
AND /v1/verify.success = true
AND regression_detected = false
AND audit record is queryable by correlation_id
```

A scenario is counted as **safe escalation** when:

```text
action is denied or skipped
AND no Kubernetes mutate action is executed
AND escalation bundle is generated
AND audit record includes reason
```

Safe escalation is not counted as auto-resolved, but it is counted as a correct safety behavior.

---

## 8. SLO / NFR Evidence

| Metric | Target | Measurement method | Measured | Pass/Fail | Evidence |
|---|---:|---|---:|---|---|
| Auto-resolve rate | >=60% over >=10 scenarios | Count scenarios with verify success | TBD | TBD | `reports/scenario-results.csv` |
| Unsafe action count | 0 | Count denied/execute logs + audit | TBD | TBD | Audit query output |
| Simulation window | >=4h | Dataset timestamps or runner duration | TBD | TBD | Scenario runner log |
| AI `/v1/detect` p99 latency | <300ms | k6/Newman timing | TBD | TBD | k6 summary |
| AI `/v1/decide` p99 latency | <500ms | k6/Newman timing | TBD | TBD | k6 summary |
| AI `/v1/verify` p99 latency | <500ms | k6/Newman timing | TBD | TBD | k6 summary |
| CDO executor p99 latency | <1000ms target for orchestration API | k6 against executor endpoint | TBD | TBD | k6 summary |
| Audit query by correlation ID | <=60s after incident closed | Query S3/Athena/local append-only index | TBD | TBD | Query screenshot |
| Tenant isolation | 100% deny cross-tenant unsafe action | Negative scenarios SH-011 + RBAC checks | TBD | TBD | `kubectl` + audit evidence |
| Image vulnerability | 0 CRITICAL, <=3 HIGH with mitigation | Trivy scan | TBD | TBD | `security/scan-results.json` |

---

## 9. Load Test Plan

### 9.1 Goal

The load test is not meant to prove production scale. It proves the CDO-02 orchestration path can handle repeated incident workflows without duplicate execution, unsafe action, or audit loss.

### 9.2 Profile

| Profile | Value |
|---|---|
| Tool | k6 or Locust |
| Duration | 5 min ramp-up + 10 min sustained |
| Virtual users | 10-30 |
| Target | CDO executor API / scenario injection endpoint |
| Traffic mix | 70% detect/decide/verify happy path, 20% denied action, 10% AI error/fallback |
| Target throughput | Start with 20 workflow requests/min; raise if stable |
| Stop condition | Any unsafe execute, audit write failure, or p99 > 3s for executor path |

### 9.3 Example k6 command

```bash
k6 run tests/load/self_heal_workflow.js \
  -e BASE_URL=https://<executor-url> \
  -e TENANT_ID=cdo-2 \
  -e TEST_MODE=mock
```

### 9.4 Expected evidence

```text
reports/k6-summary.json
reports/k6-summary.txt
CloudWatch/Prometheus screenshot
executor logs filtered by correlation_id
audit records for sampled workflow IDs
```

---

## 10. Multi-Tenant Isolation Test

| Test | Method | Expected result | Evidence |
|---|---|---|---|
| Tenant A action targets tenant A | Inject tenant-a incident with namespace tenant-a | Safety pass if action is allow-listed | Audit `safety_passed` |
| Tenant A action targets tenant B | Inject tenant-a incident but action target namespace tenant-b | Safety deny, no K8s API mutate call | Audit `denied_cross_tenant` |
| Tenant B action targets tenant A | Inject tenant-b incident but action target namespace tenant-a | Safety deny, no K8s API mutate call | Audit `denied_cross_tenant` |
| Executor is not cluster-admin | Run `kubectl auth can-i '*' '*' --as=<executor-sa>` | Should be `no` | Screenshot/log |
| Executor cannot delete namespace | Run `kubectl auth can-i delete namespace --as=<executor-sa>` | Should be `no` | Screenshot/log |
| Tenant service account cannot mutate other tenant | Use tenant-scoped SA or impersonation if implemented | Should be denied | Screenshot/log |
| Audit has tenant fields | Query audit for sampled incidents | Each record has `tenant_id`, `namespace`, `action_type`, `decision`, `reason` | Audit query output |

Example commands:

```bash
kubectl auth can-i '*' '*' --as=system:serviceaccount:platform:cdo-executor
kubectl auth can-i delete namespace --as=system:serviceaccount:platform:cdo-executor
kubectl auth can-i patch deployment -n tenant-a --as=system:serviceaccount:platform:cdo-executor
kubectl auth can-i patch deployment -n tenant-b --as=system:serviceaccount:platform:cdo-executor
```

If CDO-02 implements tenant-scoped execution identities, also run:

```bash
kubectl auth can-i patch deployment -n tenant-b --as=system:serviceaccount:tenant-a:tenant-a-executor
```

Expected result: `no`.

---

## 11. Safety Gate Test Matrix

| Check | Positive case | Negative case | Expected behavior |
|---|---|---|---|
| Tenant match | tenant_id maps to target namespace | tenant-a incident targets tenant-b | Deny negative |
| Action allow-list | `RESTART_DEPLOYMENT` | `DELETE_NAMESPACE` | Deny negative |
| Blast-radius | restart <=25% pods | restart > allowed threshold | Deny or circuit break |
| Rollback plan | runbook has rollback step | mutate action without rollback metadata | Deny |
| Verify plan | metric/log signal exists | no post-action verify signal | Escalate |
| Idempotency | first unique key | repeated same key | Deny duplicate |
| AI confidence | confidence >= threshold | confidence below threshold | Escalate |
| AI timeout/503 | AI returns normally | AI unavailable | No execute, escalate + audit |
| Audit write | audit store available | audit write fails | Stop or mark incident unsafe |

---

## 12. Security Test

| Area | Test | Target | Evidence |
|---|---|---|---|
| Image security | Trivy scan executor image | 0 CRITICAL, <=3 HIGH with mitigation | `security/trivy-executor.json` |
| Secret leakage | Grep logs for token-like strings | No SigV4, bearer token, kube token leaked | Log scan output |
| IAM least privilege | Review executor IAM role | Only AI call, S3 audit, logs, required AWS services | IAM policy file |
| K8s RBAC | `kubectl auth can-i` checks | No cluster-admin, no namespace delete | Command output |
| Cross-tenant abuse | SH-011 negative scenario | Denied before K8s mutate | Audit record |
| PII redaction | Logs sent to AI | PII/credential-like strings masked | Sample payload |

Example log scan:

```bash
grep -E "(AKIA|SECRET|TOKEN|Authorization|Bearer|kubeconfig)" reports/executor-logs.txt
```

Expected result: no sensitive values; if headers appear, they must be redacted.

---

## 13. Audit Evidence

Each incident must be queryable by `correlation_id`.

Minimum audit fields:

| Field | Required |
|---|---|
| `timestamp` | Yes |
| `correlation_id` | Yes |
| `tenant_id` | Yes |
| `namespace` | Yes |
| `action_type` | Yes |
| `decision` | Yes |
| `result` | Yes |
| `reason` | Yes for deny/failure |
| `idempotency_key` | Yes for mutate workflow |
| `dry_run_result` | Yes for mutate workflow |
| `verify_result` | Yes after verify |
| `rollback_result` | Yes if rollback attempted |

Example audit query evidence:

```bash
aws s3 ls s3://<audit-bucket>/tenant_id=tenant-a/correlation_id=<id>/
aws s3 cp s3://<audit-bucket>/tenant_id=tenant-a/correlation_id=<id>/audit.json -
```

If Athena is available:

```sql
SELECT timestamp, correlation_id, tenant_id, namespace, action_type, decision, result, reason
FROM self_heal_audit
WHERE correlation_id = '<correlation-id>'
ORDER BY timestamp ASC;
```

---

## 14. Failure / Chaos Test

| Failure | Injection method | Expected behavior | Evidence |
|---|---|---|---|
| AI `/v1/detect` timeout | Point executor to delayed endpoint or block network | No execute, escalate + audit | Executor logs + audit |
| AI `/v1/decide` returns unsupported action | Mock response with `DELETE_NAMESPACE` | Safety deny | Audit `unsupported_action` |
| Duplicate idempotency key | Send same incident twice | Second request denied | DynamoDB/lock evidence |
| Audit store unavailable | Temporarily deny audit write in test env | Stop action or mark unsafe | Logs + audit fallback |
| Verify regression | `/v1/verify` returns `regression_detected=true` | Rollback or escalate | Audit rollback/escalation |
| Cross-tenant target | tenant-a request with tenant-b namespace | Deny before K8s mutation | Audit `denied_cross_tenant` |

---

## 15. Results Summary

> Fill after W12 test execution.

| Category | Total tests | Passed | Failed | Notes |
|---|---:|---:|---:|---|
| Unit | TBD | TBD | TBD | Safety gate, schema, mapping |
| Contract | TBD | TBD | TBD | AI API headers/schema |
| E2E scenarios | TBD | TBD | TBD | >=10 required |
| Security | TBD | TBD | TBD | Tenant/RBAC/secrets |
| Load | TBD | TBD | TBD | k6/Locust |
| Chaos | TBD | TBD | TBD | AI failure, audit failure |

---

## 16. Auto-Resolve Calculation

Formula:

```text
auto_resolve_rate = auto_resolved_scenarios / total_injected_scenarios
```

Recommended reporting:

| Metric | Value |
|---|---:|
| Total injected scenarios | TBD |
| Auto-resolved scenarios | TBD |
| Safe escalations | TBD |
| Safety-denied unsafe actions | TBD |
| Failed due to platform bug | TBD |
| Auto-resolve rate | TBD |
| Unsafe action count | TBD |

Acceptance:

```text
PASS if:
- total_injected_scenarios >= 10
- simulation_window >= 4h
- auto_resolve_rate >= 60%
- unsafe_action_count = 0
```

---

## 17. Evidence Checklist Before Final Submit

- [ ] `reports/scenario-results.csv`
- [ ] `reports/k6-summary.json`
- [ ] `reports/contract-test-results.json`
- [ ] `security/trivy-executor.json`
- [ ] `evidence/kubectl-auth-can-i.txt`
- [ ] `evidence/audit-query-samples.md`
- [ ] `evidence/cloudwatch-log-insights-query.txt`
- [ ] `evidence/prometheus-screenshots/`
- [ ] `evidence/tenant-isolation-screenshots/`
- [ ] `evidence/chaos-test-results.md`
- [ ] Links to PRs/commits/Jira tasks for each test run

---

## 18. Test Gaps Acknowledged

The following gaps are acceptable only if documented honestly with mitigation:

| Gap | Impact | Mitigation |
|---|---|---|
| Full OpenTelemetry trace not completed | Less trace-level evidence for cross-service diagnosis | Keep trace schema and show logs/metrics evidence; implement OTel if time permits |
| RE2/RE3 action is Mock Mode | Demo may look less real than live K8s action | Add live sandbox test for restart/scale/dry-run patch |
| Real S3 Object Lock not enabled due account constraint | Audit tamper-evidence weaker | Use append-only fallback and document trainer approval if applicable |
| AI endpoint unavailable before T3 W12 | E2E blocked | Use skeleton/mock until integration session, then rerun with real endpoint |

---

## 19. Related Documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md)
- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`04_deployment_design.md`](04_deployment_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`08_adrs.md`](08_adrs.md)
- [`../../ai/contracts/telemetry-contract.md`](../../ai/contracts/telemetry-contract.md)
- [`../../ai/contracts/ai-api-contract.md`](../../ai/contracts/ai-api-contract.md)
- [`../../ai/contracts/deployment-contract.md`](../../ai/contracts/deployment-contract.md)

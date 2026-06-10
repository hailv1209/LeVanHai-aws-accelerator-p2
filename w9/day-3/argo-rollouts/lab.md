# Argo Rollouts — Bài tập thực hành

---

## Lab 1: Cài đặt Argo Rollouts

### Mục tiêu
Cài Argo Rollouts Controller và kubectl plugin.

### Các bước

**Bước 1: Cài Argo Rollouts Controller**

```bash
# Cài controller bằng manifest
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Verify controller đang chạy
kubectl get pods -n argo-rollouts
```

**Kết quả mong đợi:**

```
NAME                             READY   STATUS
argo-rollouts-7f4f8c9b-x2v5m    1/1     Running
```

**Bước 2: Cài kubectl plugin**

```bash
# macOS
brew install argocd-cli

# Linux (amd64)
curl -sSL -o /usr/local/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.7.0/kubectl-argo-rollouts-linux-amd64
chmod +x /usr/local/bin/kubectl-argo-rollouts

# Verify
kubectl argo rollouts version
# Output: kubectl-argo-rollouts v1.7.0+...
```

**Bước 3: Cài Argo Rollouts Dashboard (tùy chọn)**

```bash
kubectl port-forward -n argo-rollouts svc/argo-rollouts-metrics 8090:8090
# Mở http://localhost:8090/rollouts
```

---

## Lab 2: Canary Deployment — Từ đầu đến cuối

### Mục tiêu
Deploy một ứng dụng với canary strategy, thực hiện promote và abort.

### Các bước

**Bước 1: Tạo Namespace và Services**

```yaml
# step1-services.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: canary-demo

---
# Stable service — trỏ đến stable version (v1)
apiVersion: v1
kind: Service
metadata:
  name: hello-stable
  namespace: canary-demo
  labels:
    app: hello
spec:
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: hello
    track: stable

---
# Canary service — trỏ đến canary version (v2)
apiVersion: v1
kind: Service
metadata:
  name: hello-canary
  namespace: canary-demo
  labels:
    app: hello
spec:
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: hello
    track: canary
```

```bash
kubectl apply -f step1-services.yaml
```

**Bước 2: Tạo Rollout với Canary Strategy (v1)**

```yaml
# step2-rollout-v1.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: hello
  namespace: canary-demo
spec:
  replicas: 3
  revisionHistoryLimit: 3

  selector:
    matchLabels:
      app: hello

  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: paulbouwer/hello-kubernetes:1.10  # v1
          ports:
            - containerPort: 8080
          env:
            - name: MESSAGE
              value: "Hello from v1!"

  strategy:
    canary:
      stableService: hello-stable
      canaryService: hello-canary

      # Traffic routing: chia % theo ReplicaSet
      # (không cần Ingress phức tạp)
      trafficRouting:
        nginx:
          # Stable Ingress để Argo Rollouts update annotation
          stableIngress: hello-ingress

      # Metadata cho replicas
      canaryMetadata:
        labels:
          track: canary
      stableMetadata:
        labels:
          track: stable

      # Steps: 10% → pause → 30% → pause → 100%
      steps:
        - setWeight: 10
        - pause: {}
        - setWeight: 30
        - pause: {duration: 60}
        - setWeight: 60
        - pause: {}
        - setWeight: 100
```

```bash
kubectl apply -f step2-rollout-v1.yaml

# Theo dõi trạng thái
kubectl argo rollouts get rollout hello -n canary-demo --watch

# Kiểm tra ReplicaSets
kubectl get rs -n canary-demo -l app=hello
```

**Kết quả mong đợi:**

```
Name                kind   status   step  setWeight  canaryWeight
hello               Rollout Healthy  0/6   -          100%
```

**Bước 3: Quan sát Services và ReplicaSets**

```bash
# Xem pods
kubectl get pods -n canary-demo -l app=hello -o wide

# Kiểm tra stable service endpoints
kubectl get endpoints hello-stable -n canary-demo -o yaml

# Kiểm tra canary service endpoints
kubectl get endpoints hello-canary -n canary-demo -o yaml
```

**Bước 4: Upgrade lên v2**

```bash
# Cập nhật image → trigger rollout
kubectl argo rollouts set image hello \
  hello=paulbouwer/hello-kubernetes:1.11 \
  -n canary-demo

# Theo dõi
kubectl argo rollouts get rollout hello -n canary-demo --watch
```

**Kết quả mong đợi:**

```
Name     kind       status      step  setWeight  canaryWeight
hello    Rollout    Paused      1/6   10         10
  v1     ReplicaSet Healthy     3/3   -          -
  v2     ReplicaSet Healthy     0/3   -          -

# Rollout dừng ở Step 1 (setWeight: 10, pause: {})
# 10% traffic đến v2, 90% đến v1
```

**Bước 5: Manual Testing — Kiểm tra canary trước khi promote**

```bash
# Cài siege để load test (hoặc dùng curl loop)
kubectl run load-generator \
  --image=busybox \
  -n canary-demo \
  --restart=Never \
  -- sh -c "while true; do wget -q -O- http://hello-canary; done"

# Kiểm tra message từ canary (v2)
kubectl exec -it load-generator -n canary-demo -- \
  sh -c "while true; do echo '=== Canary ===' && wget -q -O- http://hello-canary; sleep 2; done"

# Kiểm tra message từ stable (v1)
kubectl exec -it load-generator -n canary-demo -- \
  sh -c "while true; do echo '=== Stable ===' && wget -q -O- http://hello-stable; sleep 2; done"
```

**Bước 6: Promote (tiếp tục rollout)**

```bash
# Promote: chuyển sang step tiếp theo
kubectl argo rollouts promote hello -n canary-demo

# Theo dõi
kubectl argo rollouts get rollout hello -n canary-demo --watch
```

**Output:**

```
Name     kind       status      step  setWeight  canaryWeight
hello    Rollout    Paused      2/6   30         30
  v1     ReplicaSet Healthy     3/3   -          -
  v2     ReplicaSet Healthy     1/3   -          -
```

**Bước 7: Abort (hủy rollout)**

```bash
# Giả lập vấn đề: rollback về v1
kubectl argo rollouts abort hello -n canary-demo

# Kiểm tra
kubectl argo rollouts get rollout hello -n canary-demo

# Kết quả:
# hello  Rollout  Degraded  -  -  0%
# → v2 bị scale down về 0, v1 scale up về 3
```

**Bước 8: Full rollout hoàn tất**

```bash
# Promote liên tục đến khi 100%
kubectl argo rollouts promote hello -n canary-demo --full

# Hoặc promote từng step
kubectl argo rollouts promote hello -n canary-demo
kubectl argo rollouts promote hello -n canary-demo
kubectl argo rollouts promote hello -n canary-demo
kubectl argo rollouts promote hello -n canary-demo

# Verify
kubectl argo rollouts status hello -n canary-demo
# Output: Healthy
```

---

## Lab 3: Blue/Green Deployment

### Mục tiêu
Triển khai blue/green strategy với auto promotion và manual gate.

### Các bước

**Bước 1: Tạo Blue/Green Rollout**

```yaml
# bg-rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: hello-bg
  namespace: canary-demo
spec:
  replicas: 5
  selector:
    matchLabels:
      app: hello-bg

  template:
    metadata:
      labels:
        app: hello-bg
    spec:
      containers:
        - name: hello
          image: paulbouwer/hello-kubernetes:1.10
          ports:
            - containerPort: 8080
          env:
            - name: MESSAGE
              value: "Blue/Green v1"

  strategy:
    blueGreen:
      # Active = đang nhận traffic thực
      activeService: hello-bg-active

      # Preview = để test trước khi switch
      previewService: hello-bg-preview

      # Số replicas
      previewReplicaCount: 2      # Preview dùng 2 replicas
      activeReplicaCount: 5       # Active dùng 5 replicas

      # Tắt auto promotion (cần manual approve)
      autoPromotionEnabled: false

      # Scale down old version sau 60s
      scaleDownDelaySeconds: 60

      # Pre-promotion analysis (smoke test)
      prePromotionAnalysis:
        templates:
          - templateName: smoke-test
        startingStep: 1
        args:
          - name: service-name
            value: hello-bg-preview
```

```bash
kubectl apply -f bg-rollout.yaml
```

**Bước 2: Kiểm tra trạng thái ban đầu**

```bash
kubectl argo rollouts get rollout hello-bg -n canary-demo --watch

# Kết quả: Healthy, 5 replicas active
```

**Bước 3: Upgrade lên v2**

```bash
kubectl argo rollouts set image hello-bg \
  hello=paulbouwer/hello-kubernetes:1.11 \
  -n canary-demo

# Kiểm tra
kubectl argo rollouts get rollout hello-bg -n canary-demo --watch

# Output:
# NAME      KIND      STRATEGY   STATUS    STEP  PREVIEW REPLICAS
# hello-bg  Rollout   blueGreen  Paused    1/1   2 (v2) / 5 (v1)
# → v2 đang ở preview (2 replicas), chưa nhận traffic
# → v1 vẫn active (5 replicas), đang nhận 100% traffic
```

**Bước 4: Test preview trước khi promote**

```bash
# Cài đặt port-forward đến preview service
kubectl port-forward -n canary-demo svc/hello-bg-preview 8080:80

# Test trên terminal khác
curl http://localhost:8080

# Output: "Blue/Green v2" (từ v2)

# So sánh với active
kubectl port-forward -n canary-demo svc/hello-bg-active 8081:80 &
curl http://localhost:8081

# Output: "Blue/Green v1" (từ v1)
```

**Bước 5: Promote (switch traffic sang v2)**

```bash
# Manual promote (vì autoPromotionEnabled=false)
kubectl argo rollouts promote hello-bg -n canary-demo

# Kết quả:
# - v2: promoted → trở thành active (5 replicas)
# - v1: scale down sau 60s
```

---

## Lab 4: Integration với Ingress Nginx

### Mục tiêu
Dùng Nginx Ingress annotation để control traffic % thực sự.

### Các bước

**Bước 1: Tạo Ingress với Argo Rollouts annotation**

```yaml
# ingress-for-canary.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-ingress
  namespace: canary-demo
  annotations:
    # Argo Rollouts sẽ update annotation này
    kubernetes.io/ingress.class: nginx
    # Argo Rollouts annotation
    rollouts.argoproj.io/use-rollout-hash: "true"
spec:
  rules:
    - host: hello.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-stable
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-for-canary.yaml
```

**Bước 2: Update Rollout để dùng Ingress**

```yaml
# Cập nhật rollout với trafficRouting
strategy:
  canary:
    stableService: hello-stable
    canaryService: hello-canary
    trafficRouting:
      nginx:
        stableIngress: hello-ingress
        # Argo Rollouts sẽ thêm annotation: nginx.ingress.kubernetes.io/canary-weight: "10"
```

```bash
kubectl apply -f updated-rollout.yaml

# Theo dõi Ingress annotation thay đổi
kubectl get ingress hello-ingress -n canary-demo -o jsonpath='{.metadata.annotations}' | jq .

# Output sẽ chứa:
# "nginx.ingress.kubernetes.io/canary-weight": "10"
# Khi promote, giá trị này tăng dần: 10 → 30 → 60 → 100
```

---

## Lab 5: Auto-pilot với Analysis

### Mục tiêu
Dùng AnalysisTemplate để tự động verify canary trước khi promote.

### Các bước

**Bước 1: Tạo AnalysisTemplate (sẽ chi tiết trong phần AnalysisTemplate)**

```bash
kubectl apply -f analysis-template-canary.yaml  # Lab 1 trong analysis-template folder
```

**Bước 2: Update Rollout với Analysis**

```yaml
# rollout-with-analysis.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: hello
  namespace: canary-demo
spec:
  # ... (same as before) ...
  strategy:
    canary:
      stableService: hello-stable
      canaryService: hello-canary

      steps:
        - setWeight: 10
        - pause: {}
        # Analysis chạy sau khi setWeight 10
        - analysis:
            templates:
              - templateName: success-rate-check
            args:
              - name: service-name
                value: hello-canary
            startingStep: 2
            # failFast: false → đợi analysis kết thúc
        - setWeight: 30
        - pause: {duration: 120}
        - setWeight: 100
```

```bash
kubectl apply -f rollout-with-analysis.yaml
```

**Bước 3: Verify automated promotion**

```bash
# Upgrade version
kubectl argo rollouts set image hello \
  hello=paulbouwer/hello-kubernetes:1.12 \
  -n canary-demo

# Argo Rollouts sẽ:
# 1. Deploy v2 với 10% canary
# 2. Dừng ở analysis step
# 3. Chạy Prometheus query từ AnalysisTemplate
# 4. Nếu success_rate > 99.9% → tự động promote
# 5. Nếu fail → tự động abort

kubectl argo rollouts get rollout hello -n canary-demo --watch
```

---

## Cleanup

```bash
kubectl delete -f step1-services.yaml
kubectl delete -f bg-rollout.yaml
kubectl delete rollout,svc -n canary-demo --all
kubectl delete ns canary-demo
```

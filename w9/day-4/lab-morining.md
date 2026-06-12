## Lab thực hành buổi sáng với GitOps-ify cụm

````
Gõ theo (Lab 0 → 7): chuẩn bị nền → cài ArgoCD → Application → self-heal → rollback → app-of-apps → sync waves → CI.
````

### Lab 0: Dựng cụm + tự viết 1 app + đưa lên Git

***k8s/web.yaml***

````
# file: gitops/k8s/web.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, namespace: demo }
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
      - { name: web, image: nginx:1.27 }
````

<img width="1150" height="506" alt="image" src="https://github.com/user-attachments/assets/d394c5b1-7859-4a77-b694-80e823e74e17" />


***Tạo cụm + repo***

````
# 1) Cụm local (driver docker)
minikube start -p w9 --driver=docker
kubectl config use-context w9
kubectl get nodes                 # STATUS Ready

# 2) Tạo repo + thư mục app
mkdir gitops && cd gitops && mkdir k8s
# -> viết k8s/web.yaml (bên phải)

# 3) Đẩy lên GitHub (repo trống tạo sẵn)
git init && git add . && git commit -m "init"
git branch -M main
git remote add origin https://github.com/<ban>/gitops.git
git push -u origin main
````

<img width="1897" height="691" alt="image" src="https://github.com/user-attachments/assets/ec4e468e-3bb5-4dd3-b272-62001aeea940" />


### Lab 1: Cài ArgoCD

***Cài + đợi sẵn sàng***

````
kubectl create ns argocd
# --server-side: tránh "annotation Too long"
# (CRD ArgoCD rất lớn, >256KB)
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/\
argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status \
  deploy/argocd-server          # đợi Running
kubectl -n argocd get pods       # argocd-* Running
````

<img width="1732" height="931" alt="image" src="https://github.com/user-attachments/assets/4b51a044-3ee1-47d8-8d4a-0fa0dbe4e81d" />

***Mở UI (tùy chọn, để demo)***

````
kubectl -n argocd port-forward \
  svc/argocd-server 8080:443 &
# mở https://localhost:8080  (user: admin)
# lấy mật khẩu ban đầu:

#Mac
kubectl -n argocd get secret \
  argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' \
  | base64 -d; echo

  #Wins
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
````

<img width="1896" height="956" alt="image" src="https://github.com/user-attachments/assets/ca4bafd3-0c49-4c49-9be1-aaffc6952c4d" />

### Lab 2: Tạo Application → ArgoCD tự sync

***Tạo file argocd/apps/web.yaml***

````
# file: argocd/apps/web.yaml  (tạo folder argocd/apps/)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: web, namespace: argocd }
spec:
  project: default
  source: { repoURL: https://github.com/<ban>/gitops.git, path: k8s }
  destination: { server: https://kubernetes.default.svc, namespace: demo }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
````

<img width="826" height="86" alt="image" src="https://github.com/user-attachments/assets/e777daac-4e00-4007-98e1-847cdfdc2151" />
<img width="1903" height="959" alt="image" src="https://github.com/user-attachments/assets/3ea75a85-50bc-4eae-adf9-78d94a0f49fe" />


***apply Application bằng TAY***

````
# tạo namespace demo
kubectl create ns demo

# k8s/web.yaml đã ở trên Git từ Lab 0.
# Application này bạn apply TAY (chưa có root):
kubectl apply -f argocd/apps/web.yaml

kubectl -n argocd get app web    # Synced/Healthy
kubectl -n demo get deploy,pod   # 2 pod web
````

<img width="781" height="487" alt="image" src="https://github.com/user-attachments/assets/eab57616-5b01-47d0-8212-f50b5fdf57f7" />
<img width="832" height="636" alt="image" src="https://github.com/user-attachments/assets/45a060e5-feef-4fe9-b399-3fe1ac03fc74" />


### Lab 3: Đổi qua Git & Self-heal

***Đổi qua Git***

````
# sửa file k8s/web.yaml: replicas 2→4, rồi push
git commit -am "2->4" && git push
# ArgoCD tự kéo -> 4 pod (~3' hoặc Refresh)
````

<img width="899" height="415" alt="image" src="https://github.com/user-attachments/assets/96baec26-1efc-45e7-8d47-11c8ea4555dd" />

<img width="1720" height="934" alt="image" src="https://github.com/user-attachments/assets/b22acec3-96e7-49ac-a496-174b351f3016" />

***Self-heal***

````
kubectl -n demo scale \
  deploy/web --replicas=9
kubectl -n demo get deploy web -w
# vài giây sau tự kéo về theo Git
````

<img width="1028" height="549" alt="image" src="https://github.com/user-attachments/assets/341e965f-88e3-4dff-abb5-2756d32e4d00" />

### Lab 4: Rollback bằng git revert < 5 phút

````
git revert HEAD --no-edit && git push
# ArgoCD sync cụm về trạng thái commit cũ
````

<img width="822" height="339" alt="image" src="https://github.com/user-attachments/assets/e1dd6f7a-91f2-4d68-bf5c-800372622693" />
<img width="1645" height="681" alt="image" src="https://github.com/user-attachments/assets/44b66050-3491-4ae3-bbe9-0c7086506367" />

### Lab 5: 1 "root" quản các app qua 1 thư mục

***argocd/root.yaml— root trỏ thư mục App con***

````
# file: argocd/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: root, namespace: argocd }
spec:
  source:
    repoURL: https://github.com/<ban>/gitops.git
    path: argocd/apps        # <- thư mục chứa các App con (đã có web.yaml)
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
````

***apply root 1 lần → root tiếp quản web***

````
git add argocd/root.yaml && git commit -m "app-of-apps"
git push
# apply ROOT bằng tay — LẦN CUỐI dùng kubectl tạo app
kubectl apply -f argocd/root.yaml
kubectl -n argocd get applications
# root + web  <- root quản web (đã ở argocd/apps/)
````

<img width="1210" height="765" alt="image" src="https://github.com/user-attachments/assets/ad275482-de50-4e16-9b1b-d9ab0bd296cf" />

### Lab 6: Ép thứ tự apply

***k8s/web.yaml— (3 resource, gắn sync-wave)***

````
# file: k8s/web.yaml
kind: ConfigMap   # v1, wave 0
metadata: { name: web-config, namespace: demo,
  annotations: { argocd.argoproj.io/sync-wave: "0" } }
data: { MESSAGE: "hello from gitops" }
---
kind: Deployment   # apps/v1, wave 1
metadata: { name: web, namespace: demo,
  annotations: { argocd.argoproj.io/sync-wave: "1" } }
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec: { containers: [ { name: web, image: nginx:1.27,
      envFrom: [ { configMapRef: { name: web-config } } ] } ] }
---
kind: Service   # v1, wave 2
metadata: { name: web, namespace: demo,
  annotations: { argocd.argoproj.io/sync-wave: "2" } }
spec: { selector: { app: web }, ports: [ { port: 80, targetPort: 80 } ] }
````

<img width="1662" height="825" alt="image" src="https://github.com/user-attachments/assets/84730599-05d1-4d03-a67e-ae9845585817" />
<img width="1527" height="559" alt="image" src="https://github.com/user-attachments/assets/1dc4c253-ff0a-4fc7-a97f-3cabba62cdbb" />


### Lab 7: plan-on-PR + branch protection

***Tạo file .github/workflows/validate.yml***

````
# file: .github/workflows/validate.yml
name: validate
on: { pull_request: { paths: ["k8s/**"] } }
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          curl -sSLo kc.tgz https://github.com/yannh/\
kubeconform/releases/download/v0.6.7/\
kubeconform-linux-amd64.tar.gz
          tar -xzf kc.tgz && sudo mv kubeconform /usr/local/bin/
      - run: kubeconform -strict -summary k8s/   # validate, KHÔNG apply
````

<img width="1778" height="850" alt="image" src="https://github.com/user-attachments/assets/04efc2f8-20b7-44a3-b579-135b7c3b9ea1" />
<img width="1480" height="743" alt="image" src="https://github.com/user-attachments/assets/a74a76b0-12a9-4951-a3b4-285957b41790" />


### Lab bonus: Add more apps to test root deploy

#### ArgoCD Applications

Các Application được khai báo trong thư mục:

```text
argocd/apps/
```

| File | App | Path |
|------|-----|------|
| `fe.yaml` | `fe` | `k8s/fe/manifests.yaml` |
| `be.yaml` | `be` | `k8s/be/manifests.yaml` |


<img width="1371" height="791" alt="image" src="https://github.com/user-attachments/assets/f5734fa6-3bff-4592-8be4-eb12c4aed8a2" />

---

#### Kubernetes Manifests

#### Frontend (`k8s/fe/manifests.yaml`)

| Resource | Name | Sync Wave | Mô tả |
|-----------|------|-----------|--------|
| ConfigMap | `fe-config` | `0` | Cấu hình ứng dụng FE |
| Deployment | `fe` | `1` | 2 replicas, image `nginx:1.27-alpine` |
| Service | `fe` | `2` | Expose ứng dụng FE qua port `80` |

##### Thứ tự apply

```text
Wave 0 → ConfigMap
Wave 1 → Deployment
Wave 2 → Service
```

<img width="1626" height="785" alt="image" src="https://github.com/user-attachments/assets/5deb9c40-ec66-429e-903f-63bff81a582a" />


---

#### Backend (`k8s/be/manifests.yaml`)

| Resource | Name | Sync Wave | Mô tả |
|-----------|------|-----------|--------|
| ConfigMap | `be-config` | `0` | Cấu hình ứng dụng BE |
| Deployment | `be` | `1` | 2 replicas, image `nginx:1.27-alpine` |
| Service | `be` | `2` | Expose ứng dụng BE qua port `8080` |

##### Thứ tự apply

```text
Wave 0 → ConfigMap
Wave 1 → Deployment
Wave 2 → Service
```

<img width="1610" height="773" alt="image" src="https://github.com/user-attachments/assets/1517291a-345d-4f03-acfa-27bbbdf16b51" />

***Kết quả app***
<img width="1454" height="886" alt="image" src="https://github.com/user-attachments/assets/26d88364-1964-4dfa-8701-cfc427befd29" />


-------

## Lab thực hành buổi chiều với GitOps-ify cụm

### Lab 1: Cài Prometheus + Argo Rollouts — qua GitOps

***tự tạo 2 file Application (Helm) trong argocd/apps/***

````
# file: argocd/apps/kube-prometheus-stack.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: kube-prometheus-stack, namespace: argocd }
spec:
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 65.1.1
    helm: { values: |    # repo: + ruleSelector, grafana adminPassword
      prometheus: { prometheusSpec: { serviceMonitorSelectorNilUsesHelmValues: false } } }
  destination: { server: https://kubernetes.default.svc, namespace: monitoring }
  syncPolicy: { automated: { prune: true, selfHeal: true },
                syncOptions: [CreateNamespace=true, ServerSideApply=true] }
# file: argocd/apps/argo-rollouts.yaml — y hệt, đổi:
#   chart: argo-rollouts ; targetRevision: 2.37.7 ; namespace: argo-rollouts
````

<img width="1639" height="824" alt="image" src="https://github.com/user-attachments/assets/8e52d838-3a08-48a7-9961-9e794d796efc" />
<img width="1643" height="838" alt="image" src="https://github.com/user-attachments/assets/8d7e51bf-d3b4-4a38-85c1-2913c3572004" />

### Lab : Viết app Flask có /metrics → build image

***tự tạo 2 file Application (Helm) trong argocd/apps/***

````
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd

spec:
  project: default

  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 65.1.1
    helm:
      values: |
        prometheus:
          prometheusSpec:
            serviceMonitorSelectorNilUsesHelmValues: false

  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
````


````
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd

spec:
  project: default

  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.37.7

  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
````

<img width="1155" height="632" alt="image" src="https://github.com/user-attachments/assets/4c5ff61b-f46c-4ed6-afbf-eb953273debf" />
<img width="1918" height="842" alt="image" src="https://github.com/user-attachments/assets/46504df9-c914-4704-9b99-9e471a26fcb9" />


### Lab 2: Viết app Flask có /metrics → build image

***Tự tạo 2 file trong thư mục app/, rồi build & nạp ảnh vào cụm.***

````
# file: app/app.py
import os, random
from flask import Flask, jsonify
from prometheus_flask_exporter import PrometheusMetrics
app = Flask(__name__)
PrometheusMetrics(app)            # tự thêm /metrics
ERR = float(os.getenv("ERROR_RATE", "0"))
VER = os.getenv("VERSION", "v1")
@app.get("/")
def index():
    if random.random() < ERR:
        return jsonify(error="injected", version=VER), 500
    return jsonify(ok=True, version=VER)
@app.get("/healthz")
def healthz(): return "ok", 200
````

````
# file: app/Dockerfile
FROM python:3.12-slim
RUN pip install flask prometheus-flask-exporter
COPY app.py /app/app.py
WORKDIR /app
ENV FLASK_APP=app.py
EXPOSE 8080
CMD ["flask","run","--host=0.0.0.0","--port=8080"]
````

<img width="1367" height="853" alt="image" src="https://github.com/user-attachments/assets/6a4b7dff-b0fd-43e3-95f1-920e3922b5c5" />
<img width="898" height="140" alt="image" src="https://github.com/user-attachments/assets/4b361e21-4b80-4caf-9d11-b9a3b5501f8d" />

### Lab 3: Viết k8s-api/ + Application → push → Prometheus thấy metric

***k8s-api/api.yaml — chứa Rollout + Service + ServiceMonitor trong 1 file***

````
# --- Rollout ---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: api
  namespace: demo
  labels:
    app: api
spec:
  replicas: 4
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: w9-api:1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: ERROR_RATE
              value: "0"
            - name: VERSION
              value: "v1"
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
  strategy:
    canary:
      steps:
        - setWeight: 25
        - pause: {}
        - setWeight: 50
        - pause:
            duration: 30
        - setWeight: 100

---
# --- Service ---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: demo
  labels:
    app: api
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: http
  selector:
    app: api

---
# --- ServiceMonitor ---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: demo
  labels:
    app: api
    release: prometheus  # match Prometheus Operator scrape label
spec:
  selector:
    matchLabels:
      app: api
  endpoints:
    - port: http
      path: /metrics
      interval: 15s

````



***argocd/apps/api.yaml — ArgoCD Application trỏ vào k8s-api/***

````
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/hailv1209/W9-lab-gitops.git
    targetRevision: HEAD
    path: k8s-api
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true

````


<img width="1607" height="246" alt="image" src="https://github.com/user-attachments/assets/ef2361b6-b5b1-4e82-a287-feff6d735e39" />
<img width="1902" height="230" alt="image" src="https://github.com/user-attachments/assets/3cc6b9a6-1522-4133-be54-e1bfbafe594f" />

### Lab 4: Rollout thả canary — promote / abort bằng tay

***Sửa api.yaml đã viết ở Lab 3 (vd VERSION v1→v2) → Rollout không lên 100% ngay, mà dừng ở 25% chờ bạn.***

````
# sửa k8s-api/api.yaml: VERSION "v1" -> "v2"
git commit -am "api v2" && git push
# ArgoCD sync -> Rollout bắt đầu canary

# theo dõi canary (cần plugin kubectl-argo-rollouts):
kubectl argo rollouts get rollout api -n demo --watch

# thấy ổn -> cho lên tiếp:
kubectl argo rollouts promote api -n demo

# thấy tệ -> hủy, về bản cũ:
kubectl argo rollouts abort api -n demo
````

<img width="863" height="735" alt="image" src="https://github.com/user-attachments/assets/5f9e200a-f935-4612-a35e-7dadae50b632" />

***# thấy ổn -> cho lên tiếp:***

<img width="881" height="96" alt="image" src="https://github.com/user-attachments/assets/403c305a-9246-4f76-8dc0-f68f107d6923" />

<img width="893" height="699" alt="image" src="https://github.com/user-attachments/assets/1b4ef342-de07-4256-b632-4c6597186190" />

<img width="975" height="764" alt="image" src="https://github.com/user-attachments/assets/0b86fdf6-189d-457b-9592-21ed21d71301" />

<img width="983" height="798" alt="image" src="https://github.com/user-attachments/assets/e5ec5d34-11a1-43c7-a851-a3b6aa639ba2" />

<img width="905" height="789" alt="image" src="https://github.com/user-attachments/assets/8a25ff17-f611-4edc-961a-01da4d312fb8" />

<img width="1020" height="741" alt="image" src="https://github.com/user-attachments/assets/e656cfdd-5c70-4a85-b797-8dfd9da69298" />


----------

## Chalange : Đưa bản mới api ra an toàn & tự bảo vệ

***Mọi thay đổi qua Git (ArgoCD sync)***

<img width="1014" height="999" alt="image" src="https://github.com/user-attachments/assets/fe6424fd-e91b-4e8a-8b2d-d5998212244e" />
<img width="776" height="788" alt="image" src="https://github.com/user-attachments/assets/8a007cc1-e65f-4470-80d8-4758c5b56a66" />
<img width="720" height="790" alt="image" src="https://github.com/user-attachments/assets/6ac7a5b0-f702-489d-9f2d-26ec922c8ed8" />
<img width="696" height="777" alt="image" src="https://github.com/user-attachments/assets/fccc39ed-d2d8-4562-8ebb-f5c2f825cd46" />
<img width="778" height="877" alt="image" src="https://github.com/user-attachments/assets/00d410f2-220c-45d1-b41f-42f8386afc9b" />

***Rollback git revert***

<img width="886" height="640" alt="image" src="https://github.com/user-attachments/assets/b514e526-f1b2-4c5f-8ccf-ae8fd70a7622" />
<img width="726" height="821" alt="image" src="https://github.com/user-attachments/assets/36b4e5a1-f524-4416-a861-6eb2af66e2cf" />
<img width="677" height="801" alt="image" src="https://github.com/user-attachments/assets/2c353c63-c94a-42aa-bd13-1fd83799df89" />

***1 SLO + 1 alert fire khi chất lượng tụt → gửi về email cá nhân. Argo Rollout có tự động abort và rollback về stable version***
<img width="950" height="423" alt="image" src="https://github.com/user-attachments/assets/715f07bd-de10-46fe-b895-fd9df832b91f" />

version trước khi push bản lỗi lên : 

<img width="667" height="611" alt="image" src="https://github.com/user-attachments/assets/4ffc3e26-9f02-44f0-bffb-6a5e15f29962" />

sau khi push bản lỗi
<img width="695" height="759" alt="image" src="https://github.com/user-attachments/assets/a3aa12d7-c249-4af5-acb1-89d2db850429" />

<img width="786" height="742" alt="image" src="https://github.com/user-attachments/assets/74be9fdd-3457-4b69-96b0-5a4c7438de1f" />



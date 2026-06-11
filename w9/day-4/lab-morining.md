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


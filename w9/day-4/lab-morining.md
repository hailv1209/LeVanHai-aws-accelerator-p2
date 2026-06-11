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

image.png

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

image.png

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

image.png
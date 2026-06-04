## Evidence running lab 
-----------
### Section sáng

#### 1. Khởi động cụm & kiểm tra
````
# minikube
minikube start

# Kiểm tra — dùng chung cho cả hai
kubectl get nodes
kubectl cluster-info
````
<img width="1523" height="710" alt="image" src="https://github.com/user-attachments/assets/7b40a41c-f166-4f73-959f-9d520f14ad1a" />


#### 2. Tạo 1 Pod, vào trong nó, rồi xoá

````
kubectl run hello --image=nginx:1.27 --port=80

kubectl get pods -o wide   # thấy IP + node
kubectl describe pod hello # đọc Events

# Vào trong Pod
kubectl exec -it hello -- sh -c "hostname; nginx -v"

# Xoá Pod trần
kubectl delete pod hello
kubectl get pods         
````
<img width="1319" height="977" alt="image" src="https://github.com/user-attachments/assets/d235b266-8a3c-4191-8125-be2816b9c1b7" />
<img width="879" height="119" alt="image" src="https://github.com/user-attachments/assets/bf24ae97-e354-4fb1-86e8-a29d02041a32" />
<img width="644" height="158" alt="image" src="https://github.com/user-attachments/assets/95b4f848-bdad-4965-86b8-ae80cccb3f5b" />

#### 3. Khai báo bằng file & apply

````
create file web.yaml

apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
      - {name: web, image: nginx:1.27}

run these command
kubectl apply -f web.yaml
kubectl get deploy,rs,pods
````

<img width="717" height="379" alt="image" src="https://github.com/user-attachments/assets/25328487-c444-44c7-92fc-799cb556d9f3" />

#### 4. Lọc theo label & "giết" 1 Pod

````
# Label — chất keo
kubectl get pods --show-labels
kubectl get pods -l app=web   # lọc
kubectl logs -l app=web --tail=3

# Self-healing: xoá toàn bộ pod cùng lúc của Deployment
kubectl delete pods -l app=web

kubectl get pods -w   # pod mới mọc lên ngay
````

<img width="1071" height="918" alt="image" src="https://github.com/user-attachments/assets/5f641610-b085-482b-8b0d-e22141099673" />


#### 5. Tách config khỏi image, inject qua env

````
# Tạo ConfigMap + Secret
kubectl create configmap app-cfg --from-literal=APP_ENV=production
kubectl create secret generic app-sec --from-literal=DB_PASSWORD=s3cr3t

# Inject vào Deployment qua env
kubectl set env deploy/web --from=configmap/app-cfg
kubectl set env deploy/web --from=secret/app-sec

# Kiểm tra ngay trong Pod
kubectl exec deploy/web -- env | findstr "APP_ENV DB_PASSWORD"
````

<img width="1060" height="399" alt="image" src="https://github.com/user-attachments/assets/05d12f91-8f23-421a-ac49-7d897c83b06a" />

-----------

### Section chiều

#### 1. Tạo Service & mở app trên browser

````
kubectl expose deployment web --type=NodePort --port=80
kubectl get svc web

# minikube tự mở URL:
minikube service web --url

# Cách CHUNG cho minikube & kind:
kubectl port-forward svc/web 8080:80
# → mở http://localhost:8080
````

<img width="1534" height="580" alt="image" src="https://github.com/user-attachments/assets/1ffccc41-2852-4eed-ac6b-2a35d3d4ed44" />

#### 2. Scale lên 5, rồi "giết" 1 Pod

````
# Scale 3 → 5
kubectl scale deploy/web --replicas=5
kubectl get pods        # đếm: 5 pod

# Tự phục hồi: xoá 1 pod
kubectl delete pod web-b8869bc99-88fxt

kubectl get pods -w     # pod mới mọc lên
````

<img width="746" height="292" alt="image" src="https://github.com/user-attachments/assets/060d9f6e-7337-4939-a63b-bca41fa70792" />
<img width="779" height="298" alt="image" src="https://github.com/user-attachments/assets/ef24c714-82a7-4c54-abcd-94b45e4a90b0" />

#### 3. Nâng version, rồi rollback

````
# Đổi image → rolling update
kubectl set image deploy/web web=nginx:1.28
kubectl rollout status deploy/web

# Xem lịch sử revision
kubectl rollout history deploy/web

# Quay lại version trước
kubectl rollout undo deploy/web
````

<img width="1086" height="914" alt="image" src="https://github.com/user-attachments/assets/d946ef15-a3bb-4259-8bb5-e3a0d640900d" />

#### 4. Cố tình làm hỏng, rồi tự chẩn đoán

````
# Deploy 1 image không tồn tại
kubectl set image deploy/web web=nginx:khong-co-tag

kubectl get pods          # thấy gì?
kubectl describe pod <pod> # đọc Events

# Cứu: rollback
kubectl rollout undo deploy/web
````

<img width="851" height="338" alt="image" src="https://github.com/user-attachments/assets/390e0bfc-c92f-412c-b623-96af9d00b83f" />
<img width="1075" height="893" alt="image" src="https://github.com/user-attachments/assets/5f051cd9-32a9-423f-a7a1-ae49f84dd4cc" />
<img width="1898" height="788" alt="image" src="https://github.com/user-attachments/assets/5bcf8838-c395-4ffc-af90-12901c0d7d96" />
<img width="720" height="281" alt="image" src="https://github.com/user-attachments/assets/4507c170-f477-4e2a-8571-4c478ad4da94" />

#### 5.  Dọn cụm khi xong

````
kubectl delete deploy/web svc/web
minikube delete          # nếu minikube
kind delete cluster --name lab # nếu kind
````

<img width="735" height="259" alt="image" src="https://github.com/user-attachments/assets/85864240-646a-44c0-a11d-b98095dc2864" />


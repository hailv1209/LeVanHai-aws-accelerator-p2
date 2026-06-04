### Evidence running lab 

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

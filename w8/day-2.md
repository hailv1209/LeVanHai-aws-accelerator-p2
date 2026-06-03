# Day 02 - Kubernetes / Container Orchestration

Du: Backend Engineer đang deploy một ứng dụng NestJS lên Kubernetes.

Giả sử bạn có hệ thống:

```
Frontend (React)
      ↓
Backend (NestJS)
      ↓
PostgreSQL
      ↓
Redis
```

Mục tiêu của Kubernetes là đảm bảo:

- Ứng dụng luôn chạy
- Tự khôi phục khi lỗi
- Scale khi tải tăng
- Cập nhật version không downtime
- Quản lý cấu hình tập trung
- Kiểm soát giao tiếp giữa các service

---

## 1. Container - Đơn vị đóng gói ứng dụng

### Vấn đề trước khi có Container

Ngày xưa deploy kiểu:

```
Server Ubuntu
├── NodeJS 18
├── PostgreSQL 16
├── Redis
└── App
```

Khi chuyển sang server khác:

```
Server B
├── NodeJS 20
├── PostgreSQL 15
```

Ứng dụng có thể lỗi ngay vì môi trường khác nhau.

### Container giải quyết thế nào?

Container đóng gói:

```
Container
├── App source code
├── NodeJS runtime
├── Dependencies
└── OS libraries
```

Ví dụ image:

```
nestjs-api:v1
```

Có thể chạy ở: Laptop, EC2, ECS, Kubernetes — và hành vi gần như giống nhau.

**Đặc tính:**

- **Isolation:** Mỗi container có filesystem riêng, network riêng, process riêng.
- **Portable:** Build một lần, chạy ở bất cứ đâu.
- **Immutable:** Không sửa container đang chạy. Muốn cập nhật: `v1 -> build image mới -> v2`. Đây là tư duy rất quan trọng khi làm DevOps.

---

## 2. Pod - Đơn vị nhỏ nhất Kubernetes quản lý

Nhiều người nghĩ:

```
Kubernetes
     ↓
Container
```

Thực tế:

```
Kubernetes
     ↓
Pod
     ↓
Container
```

Pod là lớp bọc quanh container. Ví dụ:

```
Pod
 └── NestJS Container
```

Vì Kubernetes cần thêm metadata (Labels, IP, Volumes, Network) mà Container không có.

**Đặc tính:**

- Pod có IP riêng
- Pod có thể chứa nhiều container (Sidecar Pattern)

**Vấn đề của Pod:** Pod không bền vững. Nếu Pod chết, IP biến mất và Pod mới có IP mới. Đó là lý do cần Deployment.

---

## 3. Deployment - Bộ quản lý Pod

Deployment quản lý vòng đời Pod:

```
Deployment
      ↓
ReplicaSet
      ↓
Pods
```

Ví dụ: Muốn 3 backend instances → `replicas: 3` → Kubernetes tạo Pod1, Pod2, Pod3.

**Self-healing:** Nếu Pod2 crash → Deployment phát hiện (Expected: 3, Actual: 2) → tạo Pod mới.

**Rolling Update:** v1 → v2 không downtime, từng pod được thay thế một.

---

## 4. Service - Lớp mạng ổn định

Pod IP thay đổi liên tục khi crash. Service giải quyết bằng cách cung cấp IP cố định và DNS cố định:

```
backend-service
```

Frontend gọi `http://backend-service` thay vì IP cứng. Service cũng tự động Load Balancing phân phối request đến các Pod.

---

## 5. Probe - Hệ thống Health Check

Kubernetes không biết ứng dụng có thực sự hoạt động không. Ví dụ: NestJS process còn chạy nhưng Database disconnected → app đã unusable.

- **Liveness Probe:** "App còn sống không?" → Fail → Restart container.
- **Readiness Probe:** "App đã sẵn sàng nhận traffic chưa?" → Trước khi ready, Service không route traffic đến.
- **Startup Probe:** Cho app khởi động chậm (VD: Java Spring 60s startup), tránh restart nhầm.

---

## 6. ConfigMap - Quản lý cấu hình

Tách code khỏi config:

```yaml
DB_HOST=postgres-service
LOG_LEVEL=debug
```

Cùng một image cho Production, Staging, Development — chỉ cần đổi ConfigMap.

---

## 7. Secret - Quản lý dữ liệu nhạy cảm

Tương tự ConfigMap nhưng dành cho: DB Password, JWT Secret, AWS Keys, API Tokens.

```
Secret
    ↓
Environment Variables
    ↓
Container
```

---

## 8. NetworkPolicy - Firewall của Kubernetes

Mặc định mọi Pod có thể nói chuyện với nhau. Nguy cơ: nếu frontend bị hack → có thể truy cập trực tiếp vào Database.

NetworkPolicy cho phép:

```
Frontend → Backend
```

Nhưng chặn:

```
Frontend → Database
```

Rất giống AWS Security Group nhưng ở cấp Pod.

---

## Toàn bộ hệ thống hoạt động như thế nào?

Flow thực tế:

```
User
 ↓
Ingress
 ↓
Service
 ↓
Pod (NestJS)
 ↓
Service (Postgres)
 ↓
Postgres Pod
```

```
Deployment
      ↓
    Pods
      ↓
 Containers
      ↑
ConfigMap
      ↑
 Secret

Service
      ↓
    Pods

Readiness Probe
      ↓
Service chỉ route đến Pod healthy

Liveness Probe
      ↓
Restart Pod lỗi

NetworkPolicy
      ↓
Kiểm soát Pod nào được phép giao tiếp
```

> **Lưu ý:** Hãy hiểu thật chắc Pod → Deployment → Service trước. Vì gần như mọi thành phần khác (Ingress, HPA, Helm, StatefulSet, EKS...) đều được xây dựng xoay quanh ba khái niệm cốt lõi đó.

# Day 01 - Terraform

---

## 1. Terraform ra đời để giải quyết vấn đề gì?

### Trước khi có IaC

Ví dụ bạn muốn tạo hạ tầng AWS:

```
1 VPC
2 Public Subnet
2 Private Subnet
1 ALB
1 ECS Cluster
1 RDS
```

Bạn phải vào AWS Console:

```
Click
Click
Click
Click
...
```

Có thể mất hàng giờ.

### Vấn đề

**Không thể version control:** Không ai biết Ai tạo resource? Khi nào tạo? Tại sao tạo?

**Không thể tái sử dụng:** Môi trường Dev tạo VPC A, Subnet A → môi trường Staging phải làm lại từ đầu.

**Dễ sai:** Dev tạo `t3.small`, Prod tạo `t3.medium`. Không đồng nhất.

---

## IaC là gì?

IaC = Infrastructure as Code

Thay vì click AWS Console, bạn viết:

```hcl
resource "aws_instance" "web" {
  ami           = "ami-xxxx"
  instance_type = "t3.micro"
}
```

Terraform đọc code này và tạo hạ tầng.

**Tư duy IaC:** Infrastructure trở thành Code. Giống như source code ứng dụng — bạn có thể Git, Review, Pull Request, Rollback, Audit.

---

## 2. Terraform là gì?

Terraform là công cụ IaC của HashiCorp.

Nó cho phép quản lý: AWS, Azure, GCP, Kubernetes, GitHub, Cloudflare, Datadog và hàng nghìn provider khác.

### Terraform không trực tiếp tạo AWS Resource

Terraform hoạt động như sau:

```
Terraform
      ↓
AWS Provider
      ↓
AWS API
      ↓
Resource
```

Ví dụ:

```hcl
resource "aws_s3_bucket" "logs" {
  bucket = "my-log-bucket"
}
```

Terraform gọi AWS API tạo bucket.

---

## 3. HCL là gì?

Terraform dùng ngôn ngữ **HCL (HashiCorp Configuration Language)**.

```hcl
resource "aws_s3_bucket" "logs" {
  bucket = "my-log-bucket"
}
```

**Cấu trúc cơ bản:**

- **Block:** `resource "aws_instance" "web" { }`
- **Resource Type:** `aws_instance` → Terraform biết đây là EC2
- **Resource Name:** `web` → Tên nội bộ trong Terraform
- **Attributes:** `instance_type = "t3.micro"` → Các thuộc tính của resource

---

## 4. Terraform Workflow

Đây là phần quan trọng nhất. Terraform hoạt động theo vòng đời:

```
Write
  ↓
Init
  ↓
Plan
  ↓
Apply
  ↓
Modify
  ↓
Plan
  ↓
Apply
```

### Bước 1: Viết code

```hcl
resource "aws_s3_bucket" "logs" {
  bucket = "my-log-bucket"
}
```

### Bước 2: terraform init

```bash
terraform init
```

Terraform làm gì:

- **Download Provider:** Ví dụ AWS Provider được tải về vào `.terraform/`
- **Khởi tạo working directory:** Tạo `.terraform/` và `terraform.lock.hcl`

Gần giống như `npm install`.

### Bước 3: terraform plan

```bash
terraform plan
```

Terraform so sánh:

```
Desired State
     VS
Current State
```

Ví dụ: Desired: 1 S3 Bucket, Current: 0 Bucket → Terraform hiển thị `Plan: 1 to add`

**Đây là dry-run** — chưa tạo gì cả, chỉ cho biết "Nếu apply Terraform sẽ làm gì".

**Desired State là gì?** Bạn khai báo:

```hcl
resource "aws_instance" "web" {
  instance_type = "t3.micro"
}
```

Ý nghĩa: "Tôi muốn tồn tại EC2 này" → Terraform sẽ tìm cách làm cho thực tế khớp với mong muốn đó.

### Bước 4: terraform apply

```bash
terraform apply
```

Terraform:

```
Read Plan
  ↓
Call AWS API
  ↓
Create Resource
```

---

## 5. Terraform State

Đây là phần cực kỳ quan trọng.

Sau apply, file `terraform.tfstate` xuất hiện:

```json
{
  "resources": [
    {
      "type": "aws_instance",
      "name": "web"
    }
  ]
}
```

Terraform dùng file này để nhớ "Những gì đã tạo".

**Tại sao cần State?** Lần apply tiếp theo, Terraform so sánh Code vs State vs Cloud để quyết định hành động.

---

## 6. terraform destroy

```bash
terraform destroy
```

Terraform:

```
Read State
  ↓
Find Resources
  ↓
Delete Resources
```

---

## 7. Chu trình thực tế

Ví dụ bạn muốn tạo EC2.

**main.tf:**

```hcl
resource "aws_instance" "web" {
  ami           = "ami-xxxx"
  instance_type = "t3.micro"
}
```

```bash
terraform init      # Khởi tạo
terraform plan      # Xem thay đổi → Output: "1 to add"
terraform apply     # Tạo resource → Output: "Apply complete!"
```

Đổi loại máy:

```hcl
instance_type = "t3.small"
```

```bash
terraform plan      # Output: "1 to change"
terraform apply     # Cập nhật
terraform destroy   # Output: "1 destroyed"
```

---

## Cách nhìn Terraform như một Backend Engineer

Bạn có thể xem:

```
NestJS Entity
      ↓
Migration
      ↓
Database
```

tương tự:

```
Terraform Code
      ↓
Plan
      ↓
Cloud Infrastructure
```

Hoặc:

```
Git Source Code
      ↓
Build
      ↓
Application
```

tương tự:

```
Terraform HCL
      ↓
Apply
      ↓
Infrastructure
```

---

##############################################################
# variables.tf — Input variables for K8s-on-AWS project
##############################################################

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Unique project name used as a prefix for all resources"
  type        = string
  default     = "xbrain-k8s"
}

variable "instance_type" {
  description = "EC2 instance type for the K8s node (t3.medium = 2 vCPU, 4 GB RAM)"
  type        = string
  default     = "t3.medium"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key for EC2 key pair"
  type        = string
  default     = "./k8s-ec2-key.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key used by Terraform provisioners"
  type        = string
  default     = "./k8s-ec2-key"
}

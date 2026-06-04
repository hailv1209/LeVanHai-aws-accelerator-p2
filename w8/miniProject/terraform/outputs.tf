##############################################################
# outputs.tf — Outputs after terraform apply
##############################################################

output "alb_url" {
  description = "Public URL of the Application Load Balancer — open this in your browser"
  value       = "http://${aws_lb.app.dns_name}"
}

output "ec2_public_ip" {
  description = "Public IP of the EC2 instance running the kind cluster"
  value       = aws_instance.k8s_node.public_ip
}

output "ec2_instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.k8s_node.id
}

output "alb_dns_name" {
  description = "Raw ALB DNS name (without http://)"
  value       = aws_lb.app.dns_name
}

output "ssh_command" {
  description = "SSH command to connect to the K8s node"
  value       = "ssh -i terraform/k8s-ec2-key ec2-user@${aws_instance.k8s_node.public_ip}"
}

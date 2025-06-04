# terraform/outputs.tf - AWS outputs for IoTS6

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.iot_server.id
}

output "vm_name" {
  description = "Name of the EC2 instance"
  value       = aws_instance.iot_server.tags.Name
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_eip.main.public_ip
}

output "vm_ip" {
  description = "Public IP address (alias for compatibility)"
  value       = aws_eip.main.public_ip
}

output "private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.iot_server.private_ip
}

output "public_dns" {
  description = "Public DNS name of the EC2 instance"
  value       = aws_eip.main.public_dns
}

output "ssh_connection" {
  description = "SSH connection string"
  value       = "${var.admin_username}@${aws_eip.main.public_ip}"
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.iot_server.id
}

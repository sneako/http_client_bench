output "client_public_ip" {
  description = "Public IP address of the benchmark client VM."
  value       = aws_instance.client.public_ip
}

output "server_public_ip" {
  description = "Public IP address of the benchmark server VM."
  value       = aws_instance.server.public_ip
}

output "server_private_ip" {
  description = "Private IP address of the benchmark server VM."
  value       = aws_instance.server.private_ip
}

output "ssh_user" {
  description = "SSH username for the instances."
  value       = "ubuntu"
}

output "bench_port" {
  description = "Benchmark server port."
  value       = var.bench_port
}

output "bench_tls_port" {
  description = "Benchmark server TLS port."
  value       = var.bench_tls_port
}

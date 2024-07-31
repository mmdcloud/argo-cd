output "load_balancer_ip" {
  value = aws_lb.lb.dns_name
}

# output "load_balancer_ip" {
#   value = var.subdomain_name
# }

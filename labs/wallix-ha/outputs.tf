output "lb_private_ip" {
  description = "Private address of the load balancer. This is the only entry point."
  value       = scaleway_ipam_ip.lb.address
}

output "bastion_ips" {
  description = "Reserved private addresses. a is the master and the first backend server."
  value = {
    for key, ip in scaleway_ipam_ip.bastion : key => ip.address
  }
}

output "bastion_server_ids" {
  description = "Zoned server ids, used by scripts/failover.sh to power the nodes."
  value = {
    for key, server in scaleway_instance_server.bastion : key => server.id
  }
}

output "bastion_public_ips" {
  description = "Public admin addresses, empty unless expose_bastion_admin is set."
  value = {
    for key, ip in scaleway_instance_ip.bastion : key => ip.address
  }
}

output "probe_public_ip" {
  description = "Public address of the probe."
  value       = scaleway_instance_ip.probe.address
}

output "probe_private_ip" {
  description = "Reserved private address of the probe."
  value       = scaleway_ipam_ip.probe.address
}

output "probe_private_key" {
  description = "Ed25519 private key of root on the probe."
  value       = tls_private_key.probe.private_key_openssh
  sensitive   = true
}

output "mode" {
  value = var.mode
}

output "zone" {
  value = var.zone
}

output "image" {
  value = local.bastion_image
}

output "recordings_filesystem_id" {
  description = "File Storage filesystem id, null when recordings_filesystem is false."
  value       = one(scaleway_file_filesystem.recordings[*].id)
}

output "lb_id" {
  description = "Zoned load balancer id."
  value       = scaleway_lb.this.id
}

output "project_id" {
  value = module.hub.project_id
}

output "firewall" {
  value = module.hub.firewall
}

output "failover_commands" {
  description = "Manual fallback if the hook failed (see the scwlz-vip syslog): run the line of the CARP MASTER to move the data VIPs to it from its peer."
  value       = module.hub.failover_commands
}

output "egress_public_ips" {
  value = module.hub.egress_public_ips
}

output "access" {
  value = module.hub.access
}

output "vpn" {
  value = module.hub.vpn
}

output "interlink" {
  description = "Pairing key to give to the partner or the PoP (sensitive: terraform output -json interlink)."
  value       = module.hub.interlink
  sensitive   = true
}

output "fw_root_password" {
  value     = module.hub.fw_root_password
  sensitive = true
}

output "departments" {
  value = { for k, d in module.department : k => {
    project_id          = d.project_id
    cidrs               = d.cidrs
    private_network_ids = d.private_network_ids
    iam_group_id        = d.iam_group_id
    hybrid_bypass       = d.hybrid_bypass
  } }
}

output "project_id" {
  value = module.hub.project_id
}

output "vpn" {
  value = module.hub.vpn
}

output "interlink" {
  description = "Pairing key to give to the partner or the PoP (sensitive: terraform output -json interlink)."
  value       = module.hub.interlink
  sensitive   = true
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

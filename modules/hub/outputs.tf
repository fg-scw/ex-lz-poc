output "project_id" {
  value = local.project_id
}

# Contract consumed by every department module.
output "department_contract" {
  description = "Everything a department needs to attach itself to the hub and the hybrid VPC."
  value = {
    hub_vpc_id       = scaleway_vpc.this["hub"].id
    hybrid_vpc_id    = scaleway_vpc.this["hybrid"].id
    department_pools = local.department_pools
    interlink_cidrs  = local.interlink_cidrs
  }
}

output "vpn" {
  description = "One tunnel per zone, both active (flows spread over both, each way): end them on the same stateful on-prem firewall or cluster. On-prem must announce 0.0.0.0/0."
  value = var.vpn == null ? null : {
    for k, g in local.vpn_gateways : k => {
      zone              = g.zone
      gateway_public_ip = data.scaleway_ipam_ip.vpn_gateway[k].address
      psk_secret_id     = scaleway_s2s_vpn_connection.this[k].secret_id
      bgp               = { scaleway = g.bgp_scaleway, onprem = g.bgp_onprem }
    }
  }
}

output "interlink" {
  description = "Pairing key to give to the partner or the PoP (sensitive: terraform output -json interlink)."
  sensitive   = true
  value = var.interlink == null ? null : {
    pairing_key = scaleway_interlink_link.this[0].pairing_key
    status      = scaleway_interlink_link.this[0].status
  }
}

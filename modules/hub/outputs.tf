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

output "firewall" {
  value = {
    election_vip = local.vips.hub.ip
    data_vips    = local.data_vips
    # platform_hash: a node logs "rebuild this node" until it runs this value.
    nodes = { for k, n in local.fw : k => merge(n.ip, { zone = n.zone, id = scaleway_instance_server.fw[k].id, platform_hash = local.fw_platform_hash[k] }) }
  }
}

output "failover_commands" {
  description = "Manual fallback if the hook failed (see the scwlz-vip syslog): run the line of the CARP MASTER to move the data VIPs to it from its peer."
  value = {
    for k in keys(local.fw) : k => join("; ", [
      for net, ip in scaleway_ipam_ip.data_vip :
      "scw ipam ip move ${split("/", ip.id)[1]} from-resource.mac-address=${local.fw_nic[net][local.fw_peer[k]].mac_address} to-resource.mac-address=${local.fw_nic[net][k].mac_address} to-resource.name=${var.name}-${k} region=${split("/", ip.id)[0]}"
    ])
  }
}

output "egress_public_ips" {
  description = "Internet source IPs of the landing zone (allow-list both)."
  value       = { for k, ip in scaleway_vpc_public_gateway_ip.egress : k => ip.address }
}

output "access" {
  description = "Admin access through the Public Gateway SSH bastion of each firewall zone."
  value = {
    for k, n in local.fw : k => {
      ssh   = "ssh -J ${local.bastion[k]} root@${n.ip.egress}"
      webui = "ssh -J ${local.bastion[k]} -L 8443:${n.ip.sync}:443 root@${n.ip.egress}  # then https://127.0.0.1:8443"
    }
  }
}

output "vpn" {
  description = "One tunnel per zone: configure both on the customer gateway (BGP picks the live one)."
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

output "fw_root_password" {
  description = "Generated OPNsense root password (console, WebUI); null when firewall.root_password_hash is set."
  value       = var.firewall.root_password_hash == null ? random_password.fw_root.result : null
  sensitive   = true
}

# DSI project: Egress (Internet, VPN, DSI services), HA (firewall sync),
# Hub (ingress rules -> firewall VIP) and Hybrid (Interlink, uninspected).

locals {
  department_pools = {
    pub     = cidrsubnet(var.dept_supernet, 2, 0)
    private = cidrsubnet(var.dept_supernet, 1, 1)
  }

  vpn_cidrs       = var.vpn == null ? [] : var.vpn.onprem_cidrs
  interlink_cidrs = var.interlink == null ? [] : var.interlink.onprem_cidrs

  project_id = coalesce(var.project_id, one(scaleway_account_project.this[*].id))

  # Next hop of the firewall routes towards the hub VPC router. On Scaleway
  # Private Networks the VPC router answers on 169.254.169.254 (on-link), not on
  # the first host of the subnet.
  hub_vrouter_ip = "169.254.169.254"

  # One Public Gateway per firewall zone. Both firewalls prefer pgw "a" (fw1
  # zone) so a firewall failover keeps the same PGW NAT state; "b" takes over
  # only when "a" stops answering (OPNsense gateway switching).
  pgw = {
    a = { zone = var.firewall.nodes.fw1.zone, ip = cidrhost(var.cidrs.egress, var.egress.pgw_hosts.a) }
    b = { zone = var.firewall.nodes.fw2.zone, ip = cidrhost(var.cidrs.egress, var.egress.pgw_hosts.b) }
  }

  vpcs = {
    egress = var.cidrs.egress
    ha     = var.cidrs.sync
    hub    = var.cidrs.hub
    hybrid = var.cidrs.hybrid
  }
}

resource "scaleway_account_project" "this" {
  count = var.project_id == null ? 1 : 0

  name        = var.name
  description = "Landing zone DSI: central firewall, egress and hybrid connectivity"
}

resource "scaleway_vpc" "this" {
  for_each = local.vpcs

  name                             = "${var.name}-vpc-${each.key}"
  project_id                       = local.project_id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  tags                             = var.tags
}

resource "scaleway_vpc_private_network" "this" {
  for_each = local.vpcs

  name                             = "${var.name}-pn-${each.key}"
  project_id                       = local.project_id
  vpc_id                           = scaleway_vpc.this[each.key].id
  enable_default_route_propagation = false
  tags                             = var.tags
  ipv4_subnet { subnet = each.value }
}

# --- Egress Public Gateways: Internet exit and admin SSH bastion, one per zone

resource "scaleway_iam_ssh_key" "admin" {
  for_each = toset(var.admin_ssh_public_keys)

  name       = "${var.name}-admin-${substr(sha256(each.value), 0, 8)}"
  project_id = local.project_id
  public_key = trimspace(each.value)
}

resource "scaleway_vpc_public_gateway_ip" "egress" {
  for_each = local.pgw

  project_id = local.project_id
  zone       = each.value.zone
}

resource "scaleway_vpc_public_gateway" "egress" {
  for_each = local.pgw

  name              = "${var.name}-pgw-${each.key}"
  project_id        = local.project_id
  type              = var.egress.gateway_type
  zone              = each.value.zone
  ip_id             = scaleway_vpc_public_gateway_ip.egress[each.key].id
  bastion_enabled   = true
  allowed_ip_ranges = var.admin_cidrs
  refresh_ssh_keys  = join(",", sort([for k in scaleway_iam_ssh_key.admin : k.id]))
  tags              = var.tags
}

resource "scaleway_ipam_ip" "egress_pgw" {
  for_each = local.pgw

  project_id = local.project_id
  address    = each.value.ip
  source { private_network_id = scaleway_vpc_private_network.this["egress"].id }
}

resource "scaleway_vpc_gateway_network" "egress" {
  for_each = local.pgw

  gateway_id         = scaleway_vpc_public_gateway.egress[each.key].id
  private_network_id = scaleway_vpc_private_network.this["egress"].id
  enable_masquerade  = true
  zone               = each.value.zone

  ipam_config {
    push_default_route = true
    ipam_ip_id         = scaleway_ipam_ip.egress_pgw[each.key].id
  }
}

locals {
  # fw1 sits in the zone of pgw "a", fw2 in the zone of pgw "b".
  fw_pgw = { fw1 = "a", fw2 = "b" }
  bastion = {
    for k, p in local.fw_pgw : k =>
    "bastion@${scaleway_vpc_public_gateway_ip.egress[p].address}:${scaleway_vpc_public_gateway.egress[p].bastion_port}"
  }
}

# --- Egress <-> Hub peering: on-prem (VPN) and DSI services reach the departments ---

resource "scaleway_vpc_connector" "egress_to_hub" {
  name          = "${var.name}-egress-to-hub"
  vpc_id        = scaleway_vpc.this["egress"].id
  target_vpc_id = scaleway_vpc.this["hub"].id
  tags          = var.tags
}

resource "scaleway_vpc_connector" "hub_to_egress" {
  name          = "${var.name}-hub-to-egress"
  vpc_id        = scaleway_vpc.this["hub"].id
  target_vpc_id = scaleway_vpc.this["egress"].id
  tags          = var.tags
}

resource "scaleway_vpc_route" "egress_to_departments" {
  vpc_id                   = scaleway_vpc.this["egress"].id
  description              = "${var.name}: department supernet -> hub firewall"
  destination              = var.dept_supernet
  nexthop_vpc_connector_id = scaleway_vpc_connector.egress_to_hub.id
  tags                     = var.tags
}

resource "scaleway_vpc_route" "hub_to_egress" {
  for_each = toset(concat([var.cidrs.egress], local.vpn_cidrs))

  vpc_id                   = scaleway_vpc.this["hub"].id
  description              = "${var.name}: ${each.value} via egress"
  destination              = each.value
  nexthop_vpc_connector_id = scaleway_vpc_connector.hub_to_egress.id
  tags                     = var.tags
}

# Every packet entering the hub from a peer goes to the active firewall first.
# The department supernet rule covers all present and future departments. The next hop is the
# hub data VIP: an IPAM reservation on the real NIC MAC of the CARP master,
# moved by the failover hook, so the rules themselves never change.
resource "scaleway_vpc_ingress_rule" "to_firewall" {
  for_each = toset(concat([var.dept_supernet, var.cidrs.egress], local.vpn_cidrs))

  vpc_id                     = scaleway_vpc.this["hub"].id
  source                     = each.value
  nexthop_private_network_id = scaleway_vpc_private_network.this["hub"].id
  nexthop_resource_ip        = scaleway_ipam_ip.data_vip["hub"].address
  description                = "${var.name}: ${each.value} -> active firewall"
  tags                       = var.tags
}

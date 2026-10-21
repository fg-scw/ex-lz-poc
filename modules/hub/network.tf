# DSI project: Egress (S2S VPN), Hub (transit between the departments and the
# on-prem link) and Hybrid (Interlink). There is no firewall in the hub: every
# flow leaving a department goes Private -> Pub -> Hub -> on-prem link, and the
# on-prem firewalls inspect it.
#
# Where a firewall plugs in later (README, "Ajouter un firewall dans le hub"):
#   - an HA VPC (CIDR for the node sync) and a firewall NIC in the Hub and in
#     the Egress VPC;
#   - scaleway_vpc_ingress_rule on the Hub VPC, from var.dept_supernet and the
#     on-prem CIDRs, with the firewall VIP as next hop. Those rules replace the
#     0.0.0.0/0 route of the Hub VPC below;
#   - Public Gateways in the Egress VPC for the Internet exit.
# The department module and the department states do not change.

locals {
  department_pools = {
    pub     = cidrsubnet(var.dept_supernet, 2, 0)
    private = cidrsubnet(var.dept_supernet, 1, 1)
  }

  interlink_cidrs = var.interlink == null ? [] : var.interlink.onprem_cidrs

  # The link carrying the department traffic: Interlink when set, else VPN.
  # Only this link announces dept_supernet to on-prem, so the return traffic
  # comes back through the same stateful on-prem firewall.
  interlink_is_path = var.interlink != null

  project_id = coalesce(var.project_id, one(scaleway_account_project.this[*].id))

  vpcs = {
    egress = var.cidrs.egress
    hub    = var.cidrs.hub
    hybrid = var.cidrs.hybrid
  }
}

resource "scaleway_account_project" "this" {
  count = var.project_id == null ? 1 : 0

  name        = var.name
  description = "Landing zone DSI: hub and on-prem connectivity"
}

resource "scaleway_vpc" "this" {
  for_each = local.vpcs

  name                             = "${var.name}-vpc-${each.key}"
  project_id                       = local.project_id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  # Hub only: traffic from a department peer must transit the Hub to reach the
  # Egress or Hybrid peer. Immutable.
  enable_transitivity = each.key == "hub"
  tags                = var.tags
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

# --- Egress <-> Hub peering (VPN path) ---------------------------------------

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

# --- Hybrid <-> Hub peering (Interlink path) ---------------------------------

resource "scaleway_vpc_connector" "hybrid_to_hub" {
  count = local.interlink_is_path ? 1 : 0

  name          = "${var.name}-hybrid-to-hub"
  vpc_id        = scaleway_vpc.this["hybrid"].id
  target_vpc_id = scaleway_vpc.this["hub"].id
  tags          = var.tags
}

resource "scaleway_vpc_connector" "hub_to_hybrid" {
  count = local.interlink_is_path ? 1 : 0

  name          = "${var.name}-hub-to-hybrid"
  vpc_id        = scaleway_vpc.this["hub"].id
  target_vpc_id = scaleway_vpc.this["hybrid"].id
  tags          = var.tags
}

# --- Routes ------------------------------------------------------------------
# Hub: everything not local (Internet and on-prem) goes to the VPC of the
# on-prem path, which learns 0.0.0.0/0 and the on-prem CIDRs over BGP. The
# department routes (hub_return) are added by the department module.
resource "scaleway_vpc_route" "hub_default" {
  vpc_id                   = scaleway_vpc.this["hub"].id
  description              = "${var.name}: default -> on-prem path (${local.interlink_is_path ? "interlink" : "vpn"})"
  destination              = "0.0.0.0/0"
  nexthop_vpc_connector_id = local.interlink_is_path ? scaleway_vpc_connector.hub_to_hybrid[0].id : scaleway_vpc_connector.hub_to_egress.id
  tags                     = var.tags
}

# Egress: the return traffic from on-prem to the departments.
resource "scaleway_vpc_route" "egress_to_departments" {
  vpc_id                   = scaleway_vpc.this["egress"].id
  description              = "${var.name}: department supernet -> hub"
  destination              = var.dept_supernet
  nexthop_vpc_connector_id = scaleway_vpc_connector.egress_to_hub.id
  tags                     = var.tags
}

# Hybrid: same, only with an Interlink (it is then the on-prem path).
resource "scaleway_vpc_route" "hybrid_to_departments" {
  count = local.interlink_is_path ? 1 : 0

  vpc_id                   = scaleway_vpc.this["hybrid"].id
  description              = "${var.name}: department supernet -> hub"
  destination              = var.dept_supernet
  nexthop_vpc_connector_id = scaleway_vpc_connector.hybrid_to_hub[0].id
  tags                     = var.tags
}

# --- Hub ACL -----------------------------------------------------------------
# Stateless hub ACL: blocks department-to-department transit (Pub A -> Hub -> Pub B)
# in both directions. On-prem and Internet flows are untouched, and intra-department
# Pub <-> Private traffic does not cross the Hub. A future hub firewall takes this role.
resource "scaleway_vpc_acl" "hub" {
  vpc_id         = scaleway_vpc.this["hub"].id
  is_ipv6        = false
  default_policy = "accept"

  # On the real API 0-0 means port 0: "all ports" is spelled 0-65535 (see modules/department/nacl.tf).
  rules {
    action        = "drop"
    protocol      = "ANY"
    source        = var.dept_supernet
    destination   = var.dept_supernet
    src_port_low  = 0
    src_port_high = 65535
    dst_port_low  = 0
    dst_port_high = 65535
    description   = "Inter-department traffic blocked (a hub firewall replaces this rule)"
  }
}

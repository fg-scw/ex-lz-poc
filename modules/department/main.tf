# One department: its own project, a Pub VPC peered to the DSI hub and a
# Private VPC behind it. Every flow leaving the department is inspected by the central
# firewall; Private may bypass it only towards on-prem over Interlink.
#
#   Private --peering--> Pub (transitive) --peering--> Hub (ingress rule -> hub data VIP)
#   Private --peering--> Hybrid (Interlink, bypass)            [hybrid_bypass]
#
# Network ACLs imposed on both VPCs live in nacl.tf.

locals {
  prefix = "dept-${var.name}"
  tags   = ["landing-zone", "department:${var.name}"]

  # Fixed slot sizes: /22 Pub and /21 Private per department, carved from the DSI pools.
  pub_cidr     = cidrsubnet(var.hub.department_pools.pub, 22 - tonumber(split("/", var.hub.department_pools.pub)[1]), var.index)
  private_cidr = cidrsubnet(var.hub.department_pools.private, 21 - tonumber(split("/", var.hub.department_pools.private)[1]), var.index)

  bypass = var.hybrid_bypass && length(var.hub.interlink_cidrs) > 0
}

resource "scaleway_account_project" "this" {
  name        = local.prefix
  description = "Landing zone department ${var.name}"
}

# A new project reaches the VPC API about a minute after its creation: a VPC or
# Private Network created before fails with "project ... is not found".
resource "time_sleep" "project_propagation" {
  create_duration = "90s"
  triggers        = { project_id = scaleway_account_project.this.id }
}

# --- VPCs -------------------------------------------------------------------

resource "scaleway_vpc" "pub" {
  name                             = "${local.prefix}-vpc-pub"
  project_id                       = time_sleep.project_propagation.triggers.project_id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  enable_transitivity              = true # Private reaches the hub through Pub. Immutable.
  tags                             = local.tags
}

resource "scaleway_vpc" "private" {
  name                             = "${local.prefix}-vpc-private"
  project_id                       = time_sleep.project_propagation.triggers.project_id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  tags                             = local.tags
}

resource "scaleway_vpc_private_network" "pub" {
  name                             = "${local.prefix}-pn-pub"
  project_id                       = time_sleep.project_propagation.triggers.project_id
  vpc_id                           = scaleway_vpc.pub.id
  enable_default_route_propagation = false
  tags                             = local.tags
  ipv4_subnet { subnet = local.pub_cidr }
}

resource "scaleway_vpc_private_network" "private" {
  name                             = "${local.prefix}-pn-private"
  project_id                       = time_sleep.project_propagation.triggers.project_id
  vpc_id                           = scaleway_vpc.private.id
  enable_default_route_propagation = false
  tags                             = local.tags
  ipv4_subnet { subnet = local.private_cidr }
}

# --- Peering connectors (one per side) ---------------------------------------

resource "scaleway_vpc_connector" "pub_to_hub" {
  name          = "${local.prefix}-pub-to-hub"
  vpc_id        = scaleway_vpc.pub.id
  target_vpc_id = var.hub.hub_vpc_id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "hub_to_pub" {
  name          = "hub-to-${local.prefix}-pub"
  vpc_id        = var.hub.hub_vpc_id
  target_vpc_id = scaleway_vpc.pub.id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "pub_to_private" {
  name          = "${local.prefix}-pub-to-private"
  vpc_id        = scaleway_vpc.pub.id
  target_vpc_id = scaleway_vpc.private.id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "private_to_pub" {
  name          = "${local.prefix}-private-to-pub"
  vpc_id        = scaleway_vpc.private.id
  target_vpc_id = scaleway_vpc.pub.id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "private_to_hybrid" {
  count         = local.bypass ? 1 : 0
  name          = "${local.prefix}-private-to-hybrid"
  vpc_id        = scaleway_vpc.private.id
  target_vpc_id = var.hub.hybrid_vpc_id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "hybrid_to_private" {
  count         = local.bypass ? 1 : 0
  name          = "hybrid-to-${local.prefix}-private"
  vpc_id        = var.hub.hybrid_vpc_id
  target_vpc_id = scaleway_vpc.private.id
  tags          = local.tags
}

# --- Routes -----------------------------------------------------------------
# The hub needs no per-department ingress rule: the DSI rule on the department supernet already
# sends every department source to the hub data VIP (active firewall).

resource "scaleway_vpc_route" "pub_default" {
  vpc_id                   = scaleway_vpc.pub.id
  description              = "${local.prefix}: default -> hub firewall"
  destination              = "0.0.0.0/0"
  nexthop_vpc_connector_id = scaleway_vpc_connector.pub_to_hub.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "pub_to_private" {
  vpc_id                   = scaleway_vpc.pub.id
  description              = "${local.prefix}: private"
  destination              = local.private_cidr
  nexthop_vpc_connector_id = scaleway_vpc_connector.pub_to_private.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "private_default" {
  vpc_id                   = scaleway_vpc.private.id
  description              = "${local.prefix}: default -> pub -> hub firewall"
  destination              = "0.0.0.0/0"
  nexthop_vpc_connector_id = scaleway_vpc_connector.private_to_pub.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "hub_return" {
  for_each = { pub = local.pub_cidr, private = local.private_cidr }

  vpc_id                   = var.hub.hub_vpc_id
  description              = "${local.prefix}: ${each.key} return"
  destination              = each.value
  nexthop_vpc_connector_id = scaleway_vpc_connector.hub_to_pub.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "private_to_onprem" {
  for_each = local.bypass ? toset(var.hub.interlink_cidrs) : toset([])

  vpc_id                   = scaleway_vpc.private.id
  description              = "${local.prefix}: on-prem via Interlink (bypass)"
  destination              = each.value
  nexthop_vpc_connector_id = scaleway_vpc_connector.private_to_hybrid[0].id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "hybrid_return" {
  count = local.bypass ? 1 : 0

  vpc_id                   = var.hub.hybrid_vpc_id
  description              = "${local.prefix}: private return"
  destination              = local.private_cidr
  nexthop_vpc_connector_id = scaleway_vpc_connector.hybrid_to_private[0].id
  tags                     = local.tags
}

# --- IAM: department team manages workloads, never the network ---------------

resource "scaleway_iam_group" "this" {
  name                = local.prefix
  description         = "Department ${var.name} operators (membership managed outside Terraform)"
  external_membership = true
}

resource "scaleway_iam_policy" "this" {
  name     = local.prefix
  group_id = scaleway_iam_group.this.id

  rule {
    project_ids          = [scaleway_account_project.this.id]
    permission_set_names = var.iam_permission_sets
  }
}

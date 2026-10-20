# DSI-imposed Network ACLs (the department group only has VPCReadOnly). NACLs are
# stateless and default-deny: the department may open any connection outwards, Pub may
# open any connection to Private, and from outside the department only
# var.nacl_inbound and the stateless return rules let traffic in. The return
# rules accept TCP/UDP from anywhere to ports 32768-65535, so a service
# listening on an ephemeral port is reachable from outside: what comes through
# the Hub is still filtered by the firewall; only the Interlink bypass and
# Pub -> Private are not. Traffic inside a Private Network (e.g. LB -> backends
# in Pub) is never filtered.

locals {
  any = "0.0.0.0/0"

  # Replies to connections the department opened itself (Linux ephemeral range).
  nacl_return = [for dst in [local.pub_cidr, local.private_cidr] : [
    { protocol = "TCP", source = local.any, destination = dst, port = 32768, port_end = 65535, description = "Stateless return TCP" },
    { protocol = "UDP", source = local.any, destination = dst, port = 32768, port_end = 65535, description = "Stateless return UDP" },
    { protocol = "ICMP", source = local.any, destination = dst, port = 0, port_end = 0, description = "ICMP" },
  ]]

  nacl_inbound = {
    for to in ["pub", "private"] : to => [
      for r in var.nacl_inbound : {
        protocol    = r.protocol
        source      = r.source
        destination = to == "pub" ? local.pub_cidr : local.private_cidr
        port        = r.port
        port_end    = coalesce(r.port_end, r.port)
        description = r.description != "" ? r.description : "Inbound from ${r.source}"
      } if r.to == to
    ]
  }

  nacl = {
    pub = concat(
      [
        { protocol = "ANY", source = local.pub_cidr, destination = local.any, port = 0, port_end = 0, description = "Pub outbound" },
        { protocol = "ANY", source = local.private_cidr, destination = local.any, port = 0, port_end = 0, description = "Private outbound (transit)" },
        { protocol = "ANY", source = local.any, destination = local.private_cidr, port = 0, port_end = 0, description = "To Private (transit, filtered by the Private NACL)" },
      ],
      local.nacl_return[0],
      local.nacl_inbound.pub,
    )
    private = concat(
      [
        { protocol = "ANY", source = local.private_cidr, destination = local.any, port = 0, port_end = 0, description = "Private outbound" },
        { protocol = "ANY", source = local.pub_cidr, destination = local.private_cidr, port = 0, port_end = 0, description = "Intra-department: Pub to Private" },
      ],
      [for cidr in(local.bypass ? var.hub.interlink_cidrs : []) : {
        protocol = "ANY", source = cidr, destination = local.private_cidr, port = 0, port_end = 0, description = "On-prem via Interlink (bypass)"
      }],
      local.nacl_return[1],
      local.nacl_inbound.private,
    )
  }
}

resource "scaleway_vpc_acl" "this" {
  for_each = { pub = scaleway_vpc.pub.id, private = scaleway_vpc.private.id }

  vpc_id         = each.value
  is_ipv6        = false
  default_policy = "drop"

  # On the real API a 0-0 range means "port 0", not "any port", for every
  # protocol carrying ports (ANY included): "all ports" is spelled 0-65535.
  dynamic "rules" {
    for_each = local.nacl[each.key]
    content {
      action        = "accept"
      protocol      = rules.value.protocol
      source        = rules.value.source
      destination   = rules.value.destination
      src_port_low  = 0
      src_port_high = rules.value.protocol == "ICMP" ? 0 : 65535
      dst_port_low  = rules.value.port
      dst_port_high = rules.value.protocol != "ICMP" && rules.value.port_end == 0 ? 65535 : rules.value.port_end
      description   = rules.value.description
    }
  }
}

# Data VIP failover. The hub ingress rules and the egress SNAT use fixed data
# VIPs (firewall.tf); os-scw-lz on each firewall (image/plugin, vip.sh) moves
# them in IPAM to its own NIC MACs when it is MASTER, and its cron reconciles
# every minute. Terraform ignores the VIPs' attachment after creation. The API
# key reaches the node through opnsense_secrets (firewall.tf).

resource "scaleway_iam_application" "fw_failover" {
  name        = "${var.name}-fw-failover"
  description = "CARP hook of the ${var.name} firewalls: moves the data VIPs in IPAM"
}

# IPAM has no resource-level IAM conditions: the key is limited to the DSI
# project and to requests leaving through the egress Public Gateways
# (request.ip only sees public IPs). That does not pin the key to the
# firewalls: department Internet traffic leaves through the same gateways
# (firewall SNAT, then PGW masquerade), so a key leaked from the state or a
# firewall disk also works from any department VM. It is useless from
# anywhere else.
resource "scaleway_iam_policy" "fw_failover" {
  name           = "${var.name}-fw-failover"
  application_id = scaleway_iam_application.fw_failover.id

  rule {
    project_ids          = [local.project_id]
    permission_set_names = ["IPAMFullAccess"]
    condition            = join(" || ", [for ip in scaleway_vpc_public_gateway_ip.egress : "request.ip == \"${ip.address}\""])
  }
}

# Rotation: -replace this key, then rebuild the nodes one after the other
# (fw_generation): a node reads its secrets once, at creation.
resource "scaleway_iam_api_key" "fw_failover" {
  application_id     = scaleway_iam_application.fw_failover.id
  description        = "CARP failover hook of the ${var.name} firewalls"
  default_project_id = local.project_id
}

# Failover settings of each node, read by os-scw-lz (vip.sh). Not on the
# server itself: they need the NIC MACs, which exist only after the server.
# The peer's sync IP and MACs let a node recognise a living peer (split brain
# guard of vip.sh).
resource "scaleway_instance_user_data" "scwlz" {
  for_each = local.fw

  server_id = scaleway_instance_server.fw[each.key].id
  zone      = each.value.zone
  key       = "scwlz"
  value     = <<-EOT
    CARP_VHID='${local.vips.hub.vhid}'
    CARP_IF='${local.fw_if.hub}'
    EGRESS_IF='${local.fw_if.egress}'
    NODE='${var.name}-${each.key}'
    REGION='${split("/", scaleway_vpc.this["hub"].id)[0]}'
    MOVES='${join(" ", [for net, ip in scaleway_ipam_ip.data_vip : "${split("/", ip.id)[1]}=${lower(local.fw_nic[net][each.key].mac_address)}"])}'
    ALIASES='${local.fw_if.egress}=${local.data_vips.egress}'
    SYNC_IP='${each.value.ip.sync}'
    PEER_SYNC_IP='${local.fw[local.fw_peer[each.key]].ip.sync}'
    PEER_MACS='${join(" ", [for net in ["hub", "egress"] : lower(local.fw_nic[net][local.fw_peer[each.key]].mac_address)])}'
    PEER_NODE='${var.name}-${local.fw_peer[each.key]}'
    PEER_MOVES='${join(" ", [for net, ip in scaleway_ipam_ip.data_vip : "${split("/", ip.id)[1]}=${lower(local.fw_nic[net][local.fw_peer[each.key]].mac_address)}"])}'
  EOT

  lifecycle {
    # Replaced with its server, hence destroyed while the old server still
    # exists: an in-place update waits on the old server and fails.
    replace_triggered_by = [scaleway_instance_server.fw[each.key].id]
  }
}

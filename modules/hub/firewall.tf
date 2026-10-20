# OPNsense HA pair across two zones, booted from the golden image (image/):
# OPNsense nano + os-scw-lz, without any secret. Each node pulls from its
# instance metadata (user_data, see below) its secrets, its configuration and
# its failover settings. NIC order is fixed (hub, sync, egress; names in
# fw_if) because the configuration refers to vtnet names. Terraform never
# reboots a running firewall: policy changes are pulled live, other changes
# need a rebuild (fw_generation).

locals {
  # CARP only elects the master: its VIP (virtual MAC) carries no traffic.
  # Scaleway hypervisors only accept a NIC's own MAC, so frames to a CARP
  # virtual MAC are flooded as BUM (35-45 % loss measured). The data-plane
  # VIPs (data_vips) are IPAM reservations attached to the *real* NIC MAC of
  # the master, moved by the CARP hook (failover.tf).
  carp_vhid = 10
  vips = {
    hub = { ip = cidrhost(var.cidrs.hub, var.firewall.hosts.election), vhid = local.carp_vhid, mac = format("00:00:5e:00:01:%02x", local.carp_vhid) }
  }

  # Ingress rule next hop (hub) and SNAT source to the PGWs (egress).
  data_vips = {
    hub    = cidrhost(var.cidrs.hub, var.firewall.hosts.data)
    egress = cidrhost(var.cidrs.egress, var.firewall.hosts.data)
  }

  fw_peer      = { fw1 = "fw2", fw2 = "fw1" }
  fw_nic_order = ["hub", "sync", "egress"]

  # Interfaces of the configuration, defined once: the election VIP is on the
  # hub leg, the egress VIP on the egress leg; wan is the unused public NIC.
  fw_if = { wan = "vtnet0", hub = "vtnet1", sync = "vtnet2", egress = "vtnet3" }

  fw = {
    for k, n in var.firewall.nodes : k => merge(n, {
      ip = {
        hub    = cidrhost(var.cidrs.hub, var.firewall.hosts[k])
        sync   = cidrhost(var.cidrs.sync, var.firewall.hosts[k])
        egress = cidrhost(var.cidrs.egress, var.firewall.hosts[k])
      }
    })
  }

  fw_nics = merge([
    for k in keys(local.fw) : {
      for net in local.fw_nic_order : "${k}-${net}" => { node = k, net = net }
    }
  ]...)
}

resource "random_password" "fw_root" {
  length  = 32
  special = false
}

locals {
  # Never sent to the Internet by the [EGRESS] rule: RFC1918 plus every range
  # of the landing zone and of the customer (a department in 100.64.0.0/10, say,
  # must not reach the DSI or on-prem through the Internet rule).
  internal_nets = distinct(concat(
    ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
    [var.dept_supernet], values(var.cidrs), local.vpn_cidrs, local.interlink_cidrs,
  ))

  # The customer may bring its own bcrypt hash: then no clear password at all
  # in the state.
  root_password_hash = coalesce(var.firewall.root_password_hash, random_password.fw_root.bcrypt_hash)

  # Rendered without any secret (@@KEY@@ tokens, filled on the node).
  fw_config = {
    for k, n in local.fw : k => templatefile("${path.module}/opnsense-config.xml.tftpl", {
      hostname       = "${var.name}-${k}"
      vips           = local.vips
      carp_advskew   = k == "fw1" ? 0 : 100
      carp_peer      = local.fw[local.fw_peer[k]].ip
      pfsync_peer    = local.fw[local.fw_peer[k]].ip.sync
      hub_ip         = n.ip.hub
      hub_prefix     = split("/", var.cidrs.hub)[1]
      hub_vrouter_ip = local.hub_vrouter_ip
      sync_cidr      = var.cidrs.sync
      sync_ip        = n.ip.sync
      sync_prefix    = split("/", var.cidrs.sync)[1]
      egress_ip      = n.ip.egress
      egress_vip     = local.data_vips.egress
      egress_prefix  = split("/", var.cidrs.egress)[1]
      egress_cidr    = var.cidrs.egress
      pgw            = local.pgw
      dept_supernet  = var.dept_supernet
      internal_nets  = local.internal_nets
      vpn_cidrs      = local.vpn_cidrs
      ifs            = local.fw_if
      system         = var.firewall.system
      monitors       = var.firewall.gateway_monitors
      rules          = local.policy_rules
      extra_aliases  = local.policy_aliases
      nat_rules      = local.policy_nat
      syslog = [for l in var.firewall.syslog : merge(l, {
        transport   = "${l.transport}4"
        uuid        = uuidv5("dns", "scwlz-syslog/${l.host}:${l.port}")
        description = "scwlz ${l.host}:${l.port}"
      })]
    })
  }

  # The node applies a change of the policy sections live; a change anywhere
  # else (this hash) waits for a rebuild of the node.
  fw_platform_hash = {
    for k, c in local.fw_config : k => sha256(
      replace(replace(replace(replace(c,
        "/(?s)<filter>.*?</filter>/", ""),
        "/(?s)<nat>.*?</nat>/", ""),
        "/(?s)<staticroutes[ >].*?</staticroutes>/", ""),
      "/(?s)<Firewall>.*?</Firewall>/", "")
    )
  }

  # KEY='value' lines; the node stores them root-only and deletes the key
  # from its metadata. Values never contain a single quote.
  fw_secrets = join("", [for k, v in {
    ROOT_HASH      = local.root_password_hash
    ADMIN_KEYS_B64 = base64encode("${join("\n", [for key in var.admin_ssh_public_keys : trimspace(key)])}\n")
    CARP_PASS      = random_password.carp.result
    SCW_SECRET_KEY = scaleway_iam_api_key.fw_failover.secret_key
  } : "${k}='${v}'\n"])
}

resource "random_password" "carp" {
  length  = 32
  special = false
}

resource "scaleway_ipam_ip" "fw" {
  for_each = local.fw_nics

  project_id = local.project_id
  address    = local.fw[each.value.node].ip[each.value.net]
  source { private_network_id = scaleway_vpc_private_network.this[each.value.net == "sync" ? "ha" : each.value.net].id }
}

resource "scaleway_ipam_ip" "fw_vip" {
  for_each = local.vips

  project_id = local.project_id
  address    = each.value.ip
  source { private_network_id = scaleway_vpc_private_network.this[each.key].id }
  custom_resource { mac_address = each.value.mac }
}

# Data VIPs start on fw1's real NICs; the hook moves them to the new master.
resource "scaleway_ipam_ip" "data_vip" {
  for_each = local.data_vips

  project_id = local.project_id
  address    = each.value
  source { private_network_id = scaleway_vpc_private_network.this[each.key].id }

  custom_resource {
    mac_address = local.fw_nic[each.key]["fw1"].mac_address
    name        = "${var.name}-fw1"
  }

  lifecycle {
    # Owned by the CARP hook after creation: never move a VIP back to fw1.
    ignore_changes = [custom_resource]
  }

  # The provider detaches from the MAC in the state; after a failover the
  # API refuses that (412, seen live). Move the VIP back to it first.
  # ponytail: needs the scw CLI on the runner, like fw_first_boot.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      id=${split("/", self.id)[1]} region=${split("/", self.id)[0]} to=${lower(self.custom_resource[0].mac_address)}
      cur=$(scw ipam ip get $id region=$region -o template='{{ .Resource.MacAddress }}' | tr 'A-F' 'a-f')
      [ "$cur" = "$to" ] || scw ipam ip move $id from-resource.mac-address=$cur to-resource.mac-address=$to region=$region >/dev/null
    EOT
  }
}

# Rebuilding a node = replacing its generation: server and (snapshot) volume
# are recreated together, so a rebuilt firewall never boots on a disk left
# dirty by the previous server (seen live: fsck prompt, node unreachable).
#   terraform apply -replace='terraform_data.fw_generation["fw1"]'
resource "terraform_data" "fw_generation" {
  for_each = local.fw
  input    = coalesce(each.value.snapshot_id, each.value.volume_id, each.value.image)
}

# Fresh root volume per node when booting from a snapshot.
resource "scaleway_block_volume" "fw" {
  for_each = { for k, n in local.fw : k => n if n.snapshot_id != null }

  name        = "${var.name}-${each.key}"
  project_id  = local.project_id
  zone        = each.value.zone
  snapshot_id = each.value.snapshot_id
  iops        = var.firewall.disk.iops
  size_in_gb  = var.firewall.disk.size_gb
  tags        = var.tags

  lifecycle {
    replace_triggered_by = [terraform_data.fw_generation[each.key]]
  }
}

resource "scaleway_instance_server" "fw" {
  for_each = local.fw

  name              = "${var.name}-${each.key}"
  project_id        = local.project_id
  type              = var.firewall.instance_type
  zone              = each.value.zone
  image             = each.value.image
  boot_type         = each.value.image == null ? "local" : null
  enable_dynamic_ip = false
  tags              = var.tags

  dynamic "root_volume" {
    for_each = each.value.image == null ? [coalesce(each.value.volume_id, try(scaleway_block_volume.fw[each.key].id, null))] : []
    content {
      volume_id             = root_volume.value
      volume_type           = "sbs_volume"
      size_in_gb            = var.firewall.disk.size_gb
      sbs_iops              = var.firewall.disk.iops
      boot                  = false
      delete_on_termination = false
    }
  }

  user_data = {
    opnsense_config   = base64encode(local.fw_config[each.key])
    opnsense_platform = local.fw_platform_hash[each.key]
    # Sensitive: keeps the secrets out of plan and apply output (only this key
    # is hidden, the configuration diff stays reviewable).
    opnsense_secrets = sensitive(local.fw_secrets)
  }

  lifecycle {
    # The node deletes its secrets once stored, and scwlz is managed below
    # (it needs the NIC MACs). A rebuilt node gets the secrets again.
    # type: changing it would stop and start both nodes at once; it only
    # applies to a rebuilt node (-replace one node at a time, docs/DEPLOIEMENT.md "Monter de version").
    ignore_changes       = [type, user_data["opnsense_secrets"], user_data["scwlz"]]
    replace_triggered_by = [terraform_data.fw_generation[each.key]]
  }
}

resource "scaleway_instance_private_nic" "hub" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["hub"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-hub"].id]
  zone               = each.value.zone
}

resource "scaleway_instance_private_nic" "sync" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["ha"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-sync"].id]
  zone               = each.value.zone
  depends_on         = [scaleway_instance_private_nic.hub]
}

resource "scaleway_instance_private_nic" "egress" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["egress"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-egress"].id]
  zone               = each.value.zone
  depends_on         = [scaleway_instance_private_nic.sync]
}

locals {
  fw_nic = { hub = scaleway_instance_private_nic.hub, egress = scaleway_instance_private_nic.egress }
}

# The server boots before its private NICs exist; one reboot after they are
# attached lets OPNsense apply the bootstrap config. Runs only when a node is
# (re)created, never on config changes.
# ponytail: needs the scw CLI on the runner; drop it if the image learns to hot-plug NICs.
resource "terraform_data" "fw_first_boot" {
  for_each = local.fw

  triggers_replace = [scaleway_instance_server.fw[each.key].id]

  provisioner "local-exec" {
    command = "scw instance server reboot ${split("/", scaleway_instance_server.fw[each.key].id)[1]} zone=${each.value.zone} --wait"
  }

  depends_on = [scaleway_instance_private_nic.egress]
}

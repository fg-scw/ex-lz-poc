# Private entry point for two bastions.
#
# Scaleway's default algorithm is round-robin: a TCP health check that succeeds
# on both nodes splits new sessions. `first` (HAProxy "balance first") sends
# each new session to the first server in server_ips that still has a free
# connection slot. With no max_connections, that is the master for as long as
# its health check succeeds, and the slave only after the master is marked down.
#
# The addresses are reserved in IPAM so the order is known before apply:
# .11 then .12. The numeric order matches the list order.
#
# Wallix 12 replication is not installed here. It needs the appliance CLI,
# an initialized encryption key and the wabadmin passwords. This stack only
# builds the network path the replication would sit behind.

locals {
  nodes = {
    a = { offset = 11, role = "master" }
    b = { offset = 12, role = "slave" }
  }

  # One frontend per protocol. The health check uses that same port: a dead
  # RDP proxy must not also remove SSH, and the reverse.
  services = {
    ssh   = 22
    https = 443
    rdp   = 3389
  }

  # 2242 is the Wallix admin shell. It stays off the load balancer.
  # 3306/3307 are the SQL replication ports (the product tunnels them, the
  # security group still allows the direct ports between the two nodes).
  node_ports = [22, 443, 3389, 2242, 3306, 3307]

  bastion_image = var.mode == "wallix" ? var.wallix_image_id : var.banner_image
  bastion_type  = var.mode == "wallix" ? var.bastion_type : "DEV1-S"

  banner_script_b64 = base64encode(file("${path.module}/banner/listen.py"))

  bastion_public_ip_ids = {
    for key, ip in scaleway_instance_ip.bastion : key => ip.id
  }

  admin_rules = var.expose_bastion_admin ? flatten([
    for cidr in var.admin_cidrs : [
      for port in [443, 2242] : { cidr = cidr, port = port }
    ]
  ]) : []
}

provider "scaleway" {
  region = "fr-par"
  zone   = var.zone
}

resource "scaleway_vpc" "this" {
  name       = var.name
  project_id = var.project_id
  tags       = var.tags
}

resource "scaleway_vpc_private_network" "this" {
  name       = var.name
  vpc_id     = scaleway_vpc.this.id
  project_id = var.project_id
  tags       = var.tags

  ipv4_subnet {
    subnet = var.subnet
  }
}

resource "scaleway_ipam_ip" "lb" {
  address    = cidrhost(var.subnet, 10)
  project_id = var.project_id
  tags       = var.tags

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

resource "scaleway_ipam_ip" "bastion" {
  for_each = local.nodes

  address    = cidrhost(var.subnet, each.value.offset)
  project_id = var.project_id
  tags       = var.tags

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

resource "scaleway_ipam_ip" "probe" {
  address    = cidrhost(var.subnet, 20)
  project_id = var.project_id
  tags       = var.tags

  source {
    private_network_id = scaleway_vpc_private_network.this.id
  }
}

resource "scaleway_instance_security_group" "bastion" {
  name                    = "${var.name}-bastion"
  description             = "Bastion ports from the lab subnet. Admin ports from admin_cidrs only when a public IP is attached."
  zone                    = var.zone
  project_id              = var.project_id
  tags                    = var.tags
  stateful                = true
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = local.node_ports
    content {
      action   = "accept"
      protocol = "TCP"
      port     = inbound_rule.value
      ip_range = var.subnet
    }
  }

  dynamic "inbound_rule" {
    for_each = { for rule in local.admin_rules : "${rule.cidr}-${rule.port}" => rule }
    content {
      action   = "accept"
      protocol = "TCP"
      port     = inbound_rule.value.port
      ip_range = inbound_rule.value.cidr
    }
  }
}

resource "scaleway_instance_security_group" "probe" {
  name                    = "${var.name}-probe"
  description             = "SSH from the operators. The probe reaches the load balancer over the Private Network."
  zone                    = var.zone
  project_id              = var.project_id
  tags                    = var.tags
  stateful                = true
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = toset(var.admin_cidrs)
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 22
      ip_range = inbound_rule.value
    }
  }
}

resource "tls_private_key" "probe" {
  algorithm = "ED25519"
}

resource "scaleway_instance_ip" "probe" {
  zone       = var.zone
  project_id = var.project_id
  tags       = var.tags
}

resource "scaleway_instance_ip" "bastion" {
  for_each = var.expose_bastion_admin ? local.nodes : {}

  zone       = var.zone
  project_id = var.project_id
  tags       = var.tags
}

resource "scaleway_instance_server" "bastion" {
  for_each = local.nodes

  name              = "${var.name}-${each.key}"
  type              = local.bastion_type
  image             = local.bastion_image
  zone              = var.zone
  project_id        = var.project_id
  tags              = concat(var.tags, [each.value.role])
  security_group_id = scaleway_instance_security_group.bastion.id
  # No dynamic public address. A flexible IP is attached only when
  # expose_bastion_admin reserves one; lookup yields null otherwise.
  enable_dynamic_ip = false
  ip_id             = lookup(local.bastion_public_ip_ids, each.key, null)
  state             = "started"

  # The appliance ignores cloud-init and must not receive a virtio filesystem.
  # Banner mode is an Ubuntu listener used to see which node the LB picked.
  user_data = var.mode == "banner" ? {
    cloud-init = templatefile("${path.module}/banner/cloud-init.yaml.tftpl", {
      hostname   = "${var.name}-${each.key}"
      node       = each.key
      script_b64 = local.banner_script_b64
    })
  } : null
}

# The private NIC is a second interface, attached once the server exists.
# Marketplace Ubuntu configures it by DHCP (72-scw-vpc-iface.rules). A Wallix
# image without that guest tooling will not. scripts/failover.sh reports which
# case this image is. Do not also set private_network on the server: that
# would allocate a second address beside the reserved one.
resource "scaleway_instance_private_nic" "bastion" {
  for_each = local.nodes

  server_id          = scaleway_instance_server.bastion[each.key].id
  private_network_id = scaleway_vpc_private_network.this.id
  ipam_ip_ids        = [scaleway_ipam_ip.bastion[each.key].id]
  zone               = var.zone
}

resource "scaleway_instance_server" "probe" {
  name              = "${var.name}-probe"
  type              = var.probe_type
  image             = var.banner_image
  zone              = var.zone
  project_id        = var.project_id
  tags              = var.tags
  security_group_id = scaleway_instance_security_group.probe.id
  enable_dynamic_ip = false
  ip_id             = scaleway_instance_ip.probe.id
  state             = "started"

  user_data = {
    cloud-init = templatefile("${path.module}/probe/cloud-init.yaml.tftpl", {
      public_key = tls_private_key.probe.public_key_openssh
    })
  }
}

resource "scaleway_instance_private_nic" "probe" {
  server_id          = scaleway_instance_server.probe.id
  private_network_id = scaleway_vpc_private_network.this.id
  ipam_ip_ids        = [scaleway_ipam_ip.probe.id]
  zone               = var.zone
}

resource "scaleway_lb" "this" {
  name        = var.name
  description = "Private entry point. All new sessions go to the first healthy bastion."
  type        = var.lb_type
  zone        = var.zone
  project_id  = var.project_id
  tags        = var.tags
  # Private only. A public VIP would publish RDP and SSH on the Internet.
  assign_flexible_ip   = false
  assign_flexible_ipv6 = false

  private_network {
    private_network_id = scaleway_vpc_private_network.this.id
    ipam_ids           = [scaleway_ipam_ip.lb.id]
  }
}

resource "scaleway_lb_backend" "svc" {
  for_each = local.services

  lb_id                  = scaleway_lb.this.id
  name                   = each.key
  forward_protocol       = "tcp"
  forward_port           = each.value
  forward_port_algorithm = "first"
  # Master first. Do not set max_connections: a full slot would spill onto the
  # slave while the master is still healthy.
  server_ips                   = [for key in ["a", "b"] : scaleway_ipam_ip.bastion[key].address]
  sticky_sessions              = "none"
  proxy_protocol               = "none"
  on_marked_down_action        = "shutdown_sessions"
  health_check_port            = each.value
  health_check_delay           = "1s"
  health_check_timeout         = "1s"
  health_check_max_retries     = 2
  health_check_transient_delay = "0.5s"

  health_check_tcp {}
}

resource "scaleway_lb_frontend" "svc" {
  for_each = local.services

  lb_id        = scaleway_lb.this.id
  backend_id   = scaleway_lb_backend.svc[each.key].id
  name         = each.key
  inbound_port = each.value
}

# Standalone filesystem. Wallix mounts NFS from its own UI; the instance
# filesystems block is a virtio-fs attachment the appliance does not handle.
resource "scaleway_file_filesystem" "recordings" {
  count = var.recordings_filesystem ? 1 : 0

  name       = "${var.name}-recordings"
  size_in_gb = var.recordings_size_gb
  region     = "fr-par"
  project_id = var.project_id
  tags       = var.tags
}

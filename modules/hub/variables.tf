variable "name" {
  description = "DSI project name and resource prefix."
  type        = string
  default     = "dsi-hub"
  nullable    = false
}

variable "project_id" {
  description = "Existing project to deploy the DSI into; null creates a dedicated project named after var.name."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags set on every taggable resource of the DSI."
  type        = list(string)
  default     = ["landing-zone", "dsi"]
  nullable    = false
}

variable "cidrs" {
  description = "DSI Private Networks. Must not overlap the department supernet nor on-prem."
  type = object({
    egress = optional(string, "10.0.4.0/24")
    sync   = optional(string, "10.255.0.0/24")
    hub    = optional(string, "172.16.0.0/24")
    hybrid = optional(string, "10.0.5.0/24")
  })
  default  = {}
  nullable = false
}

variable "dept_supernet" {
  description = "Range holding every department CIDR: first /12 for Pub slots (/22), second /11 for Private slots (/21). One ingress rule and one FW alias cover all departments."
  type        = string
  default     = "10.64.0.0/10"

  validation {
    condition     = can(cidrhost(var.dept_supernet, 0)) && tonumber(split("/", var.dept_supernet)[1]) <= 10
    error_message = "dept_supernet must be a CIDR of /10 or larger (1024 department slots)."
  }

  # No cidrcontains in Terraform: compare the first and last address of each
  # range as integers. Covers the DSI networks, the department supernet and the
  # on-prem ranges (VPN, Interlink): an overlap breaks routing and peering,
  # and CIDRs cannot be modified afterwards.
  validation {
    condition = try(!anytrue(flatten([
      for ranges in [concat(
        values(var.cidrs), [var.dept_supernet],
        var.vpn == null ? [] : var.vpn.onprem_cidrs,
        var.interlink == null ? [] : var.interlink.onprem_cidrs,
        )] : [
        for i, a in ranges : [
          for j, b in ranges : i < j &&
          sum([for k, o in split(".", cidrhost(a, 0)) : tonumber(o) * pow(256, 3 - k)]) <= sum([for k, o in split(".", cidrhost(b, -1)) : tonumber(o) * pow(256, 3 - k)]) &&
          sum([for k, o in split(".", cidrhost(b, 0)) : tonumber(o) * pow(256, 3 - k)]) <= sum([for k, o in split(".", cidrhost(a, -1)) : tonumber(o) * pow(256, 3 - k)])
        ]
      ]
    ])), false)
    error_message = "cidrs, dept_supernet, vpn.onprem_cidrs and interlink.onprem_cidrs must be valid IPv4 CIDRs that do not overlap each other."
  }
  nullable = false
}

variable "admin_cidrs" {
  description = "Public CIDRs allowed on the Public Gateway SSH bastion."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "admin_cidrs must contain valid, non-default CIDRs."
  }
}

variable "admin_ssh_public_keys" {
  description = "OpenSSH public keys for the bastion and the firewalls' root account."
  type        = list(string)

  validation {
    condition     = length(var.admin_ssh_public_keys) > 0 && alltrue([for k in var.admin_ssh_public_keys : can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)) ", trimspace(k)))])
    error_message = "admin_ssh_public_keys must contain OpenSSH public keys."
  }
}

variable "firewall" {
  description = "OPNsense HA pair. Each node boots from exactly one of: an image (label or zone-local ID), an existing SBS volume (<zone>/<uuid>) or a block snapshot, normally the golden image built by image/build.sh (a fresh volume is created from it). Node zones must offer Public Gateways, VPN and LB (fr-par-1 and fr-par-2, not fr-par-3)."
  type = object({
    instance_type = optional(string, "POP2-2C-8G")
    # bcrypt hash of the root password, computed by the customer (htpasswd -nbB
    # root <password>). null generates a password (output fw_root_password).
    root_password_hash = optional(string)
    disk = optional(object({
      size_gb = optional(number, 25)
      iops    = optional(number, 5000)
    }), {})
    # Host numbers in the hub (election, data VIPs, nodes) and egress networks.
    hosts = optional(object({
      election = optional(number, 9)  # CARP election VIP, hub only
      data     = optional(number, 10) # IPAM data VIPs, hub and egress
      fw1      = optional(number, 11)
      fw2      = optional(number, 12)
    }), {})
    system = optional(object({
      timezone = optional(string, "Europe/Paris")
      dns      = optional(list(string), ["1.1.1.1"])
      ntp      = optional(list(string), ["0.opnsense.pool.ntp.org", "1.opnsense.pool.ntp.org"])
    }), {})
    # dpinger targets, one per Public Gateway.
    gateway_monitors = optional(object({
      a = optional(string, "1.0.0.1")
      b = optional(string, "9.9.9.9")
    }), {})
    # Remote syslog collectors (UDP or TCP, RFC 5424). The logs also stay on
    # the node. Platform setting: changing it means rebuilding the nodes.
    syslog = optional(list(object({
      host      = string
      port      = optional(number, 514)
      transport = optional(string, "udp")
    })), [])
    nodes = map(object({
      zone        = string
      image       = optional(string)
      volume_id   = optional(string)
      snapshot_id = optional(string)
    }))
  })

  validation {
    condition     = var.firewall.root_password_hash == null || can(regex("^\\$2[aby]\\$[0-9]{2}\\$[./A-Za-z0-9]{53}$", var.firewall.root_password_hash))
    error_message = "firewall.root_password_hash must be a bcrypt hash."
  }

  validation {
    condition     = length(distinct(concat(values(var.firewall.hosts), values(var.egress.pgw_hosts)))) == 6
    error_message = "firewall.hosts must be 4 distinct host numbers, none equal to egress.pgw_hosts."
  }

  # host: no XML special character can get through.
  validation {
    condition = alltrue([
      for l in var.firewall.syslog :
      can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$", l.host)) && l.port >= 1 && l.port <= 65535 && contains(["udp", "tcp"], l.transport)
    ]) && length(distinct([for l in var.firewall.syslog : "${l.host}:${l.port}"])) == length(var.firewall.syslog)
    error_message = "firewall.syslog: host is an IPv4 address or a host name, port 1-65535, transport udp|tcp, one entry per host:port."
  }

  validation {
    condition     = length(var.firewall.system.dns) > 0 && length(var.firewall.system.ntp) > 0
    error_message = "firewall.system.dns and firewall.system.ntp need at least one entry."
  }

  validation {
    condition     = toset(keys(var.firewall.nodes)) == toset(["fw1", "fw2"])
    error_message = "firewall.nodes must define exactly fw1 and fw2."
  }

  validation {
    condition     = alltrue([for n in values(var.firewall.nodes) : length(compact([n.image, n.volume_id, n.snapshot_id])) == 1])
    error_message = "Each firewall node needs exactly one of image, volume_id or snapshot_id."
  }

  validation {
    condition     = alltrue([for n in values(var.firewall.nodes) : n.volume_id == null || startswith(coalesce(n.volume_id, "-"), "${n.zone}/")])
    error_message = "volume_id must be prefixed with the node zone (<zone>/<uuid>)."
  }
}

variable "egress" {
  description = "Egress Public Gateways: type and host number of each one in the egress network."
  type = object({
    gateway_type = optional(string, "VPC-GW-S")
    pgw_hosts = optional(object({
      a = optional(number, 2)
      b = optional(number, 3)
    }), {})
  })
  default  = {}
  nullable = false
}

variable "vpn" {
  description = "Optional S2S VPN in the Egress VPC, one gateway per firewall zone. On-prem flows through it are inspected by the firewall."
  type = object({
    customer_gateway_ip = string
    customer_asn        = number
    onprem_cidrs        = list(string)
    gateway_type        = optional(string, "VGW-S")
    # IKE (phase 1) and ESP (phase 2) proposals offered to the customer gateway.
    ciphers = optional(object({
      ike = optional(object({
        encryption = optional(string, "aes256")
        integrity  = optional(string, "sha256")
        dh_group   = optional(string, "modp2048")
      }), {})
      esp = optional(object({
        encryption = optional(string, "aes256")
        integrity  = optional(string, "sha256")
        dh_group   = optional(string, "modp2048")
      }), {})
    }), {})
    # BGP /30 of each tunnel (a, b): Scaleway side and on-prem side.
    bgp_links = optional(object({
      a = optional(object({ scaleway = string, onprem = string }), { scaleway = "169.254.100.1/30", onprem = "169.254.100.2/30" })
      b = optional(object({ scaleway = string, onprem = string }), { scaleway = "169.254.100.5/30", onprem = "169.254.100.6/30" })
    }), {})
  })
  default = null

  validation {
    condition     = var.vpn == null || alltrue([for l in values(var.vpn.bgp_links) : alltrue([for c in values(l) : can(cidrhost(c, 0))])])
    error_message = "vpn.bgp_links must hold valid CIDRs (/30)."
  }
}

variable "interlink" {
  description = "Optional Interlink on the Hybrid VPC. Department Private VPCs with hybrid_bypass reach these on-prem CIDRs without inspection."
  type = object({
    pop_id         = string
    bandwidth_mbps = number
    onprem_cidrs   = list(string)
    partner_id     = optional(string) # hosted link
    connection_id  = optional(string) # self-hosted link
    peer_asn       = optional(number) # self-hosted only
    vlan           = optional(number) # self-hosted only
  })
  default = null

  validation {
    condition     = var.interlink == null || (try(var.interlink.partner_id, null) == null) != (try(var.interlink.connection_id, null) == null)
    error_message = "interlink needs either partner_id (hosted) or connection_id (self-hosted)."
  }
}

variable "policy" {
  description = <<-EOT
    Customer firewall policy, rendered into the live-applied sections of the
    OPNsense configuration. Rules are evaluated in order, before the default
    [EW] (inter-department block), [DSI], [VPN] and [EGRESS] rules.
    - aliases: name => CIDRs, usable as source/destination.
    - rules: source/destination are an alias (built-in: DEPT_NETS, DSI_EGRESS_NET,
      ONPREM_VPN, EGRESS_PGWS, internal_nets, or yours), a CIDR or "any".
    - nat_outbound: SNAT on the egress interface, target defaults to the egress data VIP.
  EOT
  type = object({
    aliases = optional(map(list(string)), {})
    rules = optional(list(object({
      description = string
      action      = string # pass | block
      interface   = optional(string, "hub")
      source      = string
      destination = string
      protocol    = optional(string, "any")
      port        = optional(number)
      port_end    = optional(number)
      state       = optional(string, "sloppy")
    })), [])
    nat_outbound = optional(list(object({
      description = string
      source      = string
      destination = optional(string, "any")
      target      = optional(string)
    })), [])
  })
  default  = {}
  nullable = false

  # Built-in alias names (opnsense-config.xml.tftpl) are listed here: a
  # variable cannot read locals.
  validation {
    condition = alltrue([
      for e in concat(
        [for r in var.policy.rules : r.source], [for r in var.policy.rules : r.destination],
        [for n in var.policy.nat_outbound : n.source], [for n in var.policy.nat_outbound : n.destination]
        ) : e == "any" || can(cidrhost(e, 0)) || contains(
        concat(["DEPT_NETS", "DSI_EGRESS_NET", "ONPREM_VPN", "EGRESS_PGWS", "internal_nets"], keys(var.policy.aliases)), e
      )
    ])
    error_message = "policy source/destination must be \"any\", a valid CIDR or an existing alias name."
  }

  validation {
    condition = alltrue([
      for r in var.policy.rules :
      contains(["pass", "block"], r.action) && contains(["hub", "egress"], r.interface) &&
      contains(["any", "tcp", "udp", "icmp"], r.protocol) && contains(["sloppy", "keep"], r.state)
    ])
    error_message = "policy.rules: action pass|block, interface hub|egress, protocol any|tcp|udp|icmp, state sloppy|keep."
  }

  validation {
    condition = alltrue([
      for r in var.policy.rules : r.port == null ? r.port_end == null : (contains(["tcp", "udp"], r.protocol) && r.port >= 1 && r.port <= 65535 && coalesce(r.port_end, r.port) >= r.port && coalesce(r.port_end, r.port) <= 65535)
    ])
    error_message = "policy.rules: port needs protocol tcp or udp, within 1-65535, and port_end >= port."
  }

  # No XML injection through free text; unique descriptions seed the rule UUIDs.
  validation {
    condition = alltrue([
      for d in concat([for r in var.policy.rules : r.description], [for n in var.policy.nat_outbound : n.description]) :
      length(d) > 0 && !can(regex("[<>&]", d))
    ]) && length(distinct([for r in var.policy.rules : r.description])) == length(var.policy.rules)
    error_message = "policy descriptions must be unique, non-empty and free of <, > and &."
  }

  validation {
    condition = alltrue([for name, cidrs in var.policy.aliases :
      can(regex("^[A-Za-z][A-Za-z0-9_]{0,31}$", name)) && !contains(["DEPT_NETS", "DSI_EGRESS_NET", "ONPREM_VPN", "EGRESS_PGWS", "internal_nets"], name) &&
      length(cidrs) > 0 && alltrue([for c in cidrs : can(cidrhost(c, 0))])
    ])
    error_message = "policy.aliases: names are letters, digits and _ (32 max), not a built-in alias; values are non-empty lists of valid CIDRs."
  }

  validation {
    condition     = alltrue([for n in var.policy.nat_outbound : n.target == null || can(cidrhost("${n.target}/32", 0))])
    error_message = "policy.nat_outbound target must be an IPv4 address."
  }
}

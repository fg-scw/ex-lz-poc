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
    hub    = optional(string, "172.16.0.0/24")
    hybrid = optional(string, "10.0.5.0/24")
  })
  default  = {}
  nullable = false
}

variable "dept_supernet" {
  description = "Range holding every department CIDR: first /12 for Pub slots (/22), second /11 for Private slots (/21). One route and one BGP prefix cover all departments."
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

variable "vpn" {
  description = "Optional S2S VPN in the Egress VPC, one gateway per zone. It carries the department traffic when there is no Interlink; on-prem must then announce 0.0.0.0/0."
  type = object({
    customer_gateway_ip = string
    customer_asn        = number
    onprem_cidrs        = list(string)
    gateway_type        = optional(string, "VGW-S")
    # Zone of each gateway (a, b): VPN gateways exist in fr-par-1 and fr-par-2.
    zones = optional(object({
      a = optional(string, "fr-par-1")
      b = optional(string, "fr-par-2")
    }), {})
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
  description = "Optional Interlink on the Hybrid VPC. It carries the department traffic when set (on-prem must announce 0.0.0.0/0); Private VPCs with hybrid_bypass also reach the on-prem CIDRs directly. At least one of vpn and interlink is required."
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

  # Without a link the departments would have no exit.
  validation {
    condition     = var.interlink != null || var.vpn != null
    error_message = "Set vpn or interlink: department traffic leaves through an on-prem link."
  }
}

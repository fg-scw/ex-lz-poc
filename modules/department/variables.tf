variable "name" {
  description = "Department key; also the project and resource name suffix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must be 2-24 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "index" {
  description = "Permanent, unique index (0-1023) that sets the department CIDRs."
  type        = number

  validation {
    condition     = var.index >= 0 && var.index < 1024 && floor(var.index) == var.index
    error_message = "index must be an integer between 0 and 1023."
  }
}

variable "hybrid_bypass" {
  description = "Peer the Private VPC with the Hybrid VPC (Interlink, no firewall inspection). Needs an Interlink on the hub."
  type        = bool
  default     = false
}

variable "nacl_inbound" {
  description = "Flows allowed INTO the department from outside it (on-prem, DSI, other departments once the firewall allows them). Everything else is dropped by the department NACL."
  type = list(object({
    to          = string # pub | private
    source      = string
    protocol    = optional(string, "TCP") # ANY | TCP | UDP | ICMP
    port        = optional(number, 0)     # 0 = all ports
    port_end    = optional(number)        # range end, defaults to port
    description = optional(string, "")
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.nacl_inbound : contains(["pub", "private"], r.to) && contains(["ANY", "TCP", "UDP", "ICMP"], r.protocol) && can(cidrhost(r.source, 0))])
    error_message = "nacl_inbound needs to = pub|private, protocol = ANY|TCP|UDP|ICMP and a CIDR source."
  }
}

variable "hub" {
  description = "Hub outputs consumed by the department (module.hub.department_contract)."
  type = object({
    hub_vpc_id       = string
    hybrid_vpc_id    = string
    department_pools = object({ pub = string, private = string })
    interlink_cidrs  = list(string)
  })
}

variable "iam_permission_sets" {
  description = "Permission sets granted to the department group on its project. No VPC, gateway, VPN or Interlink rights: network stays under DSI control."
  type        = list(string)
  default = [
    "InstancesFullAccess",
    "BlockStorageFullAccess",
    "LoadBalancersFullAccess",
    "EdgeServicesFullAccess",
    "KubernetesFullAccess",
    "RelationalDatabasesFullAccess",
    "ObjectStorageFullAccess",
    "SecretManagerFullAccess",
    "ObservabilityFullAccess",
    "IPAMFullAccess",
    "PrivateNetworksReadOnly",
    "VPCReadOnly",
  ]
  nullable = false
}

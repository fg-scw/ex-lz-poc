# Typed and validated by modules/hub: "any" only forwards the values, and null
# means "module default".

variable "admin_cidrs" {
  description = "Public IPs allowed on the Public Gateway SSH bastion."
  type        = list(string)
}

variable "admin_ssh_public_keys" {
  description = "OpenSSH public keys of the bastion and of the firewalls' root account."
  type        = list(string)
}

variable "firewall" {
  description = "Golden image snapshot of each zone, instance type, syslog... (modules/hub, docs/CONFIGURATION.md)."
  type        = any
}

variable "vpn" {
  description = "Inspected on-prem access (Egress VPC). null = none."
  type        = any
  default     = null
}

variable "interlink" {
  description = "Uninspected on-prem access for department Private VPCs (Hybrid VPC). null = none."
  type        = any
  default     = null
}

variable "policy" {
  description = "Custom firewall policy: aliases, rules, nat_outbound (see terraform.tfvars.example)."
  type        = any
  default     = {}
}

variable "departments" {
  description = "Departments by name. index (0-1023) is permanent and unique: it sets the CIDRs. hybrid_bypass peers the Private VPC with the Hybrid VPC. nacl_inbound opens flows INTO the department."
  type = map(object({
    index         = number
    hybrid_bypass = optional(bool, false)
    nacl_inbound = optional(list(object({
      to          = string # pub | private
      source      = string
      protocol    = optional(string, "TCP") # ANY | TCP | UDP | ICMP
      port        = optional(number, 0)     # 0 = all ports
      port_end    = optional(number)        # range end, defaults to port
      description = optional(string, "")
    })), [])
  }))
  default = {}

  validation {
    condition     = length(distinct([for d in values(var.departments) : d.index])) == length(var.departments)
    error_message = "departments: each department needs a unique index."
  }

  # Without an Interlink the bypass would silently do nothing.
  validation {
    condition     = var.interlink != null || !anytrue([for d in values(var.departments) : d.hybrid_bypass])
    error_message = "departments: hybrid_bypass needs interlink to be set."
  }
}

variable "iam_permission_sets" {
  description = "Permission sets of the department IAM groups (same for all); null = module default."
  type        = any
  default     = null
}

# --- Advanced overrides ---------------------------------------------------------

variable "name" {
  description = "Hub project name and resource prefix; null = module default."
  type        = any
  default     = null
}

variable "project_id" {
  description = "Existing project to deploy the hub into; null = module default."
  type        = any
  default     = null
}

variable "tags" {
  description = "Tags of every hub resource; null = module default."
  type        = any
  default     = null
}

variable "cidrs" {
  description = "Egress, sync, hub and hybrid CIDRs; null = module default."
  type        = any
  default     = null
}

variable "dept_supernet" {
  description = "Block holding every department; null = module default."
  type        = any
  default     = null
}

variable "egress" {
  description = "Public Gateway settings; null = module default."
  type        = any
  default     = null
}

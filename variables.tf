# Typed and validated by modules/hub: "any" only forwards the values, and null
# means "module default".

variable "vpn" {
  description = "S2S VPN to the on-prem firewalls (Egress VPC). Carries the department traffic when there is no interlink. At least one of vpn and interlink is required."
  type        = any
  default     = null
}

variable "interlink" {
  description = "Interlink to the on-prem firewalls (Hybrid VPC). Carries the department traffic when set. At least one of vpn and interlink is required."
  type        = any
  default     = null
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
  description = "Egress, hub and hybrid CIDRs; null = module default."
  type        = any
  default     = null
}

variable "dept_supernet" {
  description = "Block holding every department; null = module default."
  type        = any
  default     = null
}

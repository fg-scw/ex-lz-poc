variable "name" {
  description = "Prefix of every lab resource."
  type        = string
  default     = "wallix-ha"
}

variable "project_id" {
  description = "Existing Scaleway project. Null uses the provider default."
  type        = string
  default     = null
}

variable "zone" {
  description = "Zone of the instances, the load balancer and the security groups. The Wallix image in this lab exists in fr-par-1."
  type        = string
  default     = "fr-par-1"
}

variable "mode" {
  description = "wallix boots the appliance image. banner boots Ubuntu listeners that identify themselves, so the pinning of the load balancer can be observed."
  type        = string
  default     = "wallix"

  validation {
    condition     = contains(["wallix", "banner"], var.mode)
    error_message = "mode must be wallix or banner."
  }
}

variable "wallix_image_id" {
  description = "Zonal image id of wallix-bastion-12.3.6 in fr-par-1."
  type        = string
  default     = "9a4410b3-f8b4-4aba-aab5-73447ce5710e"
}

variable "banner_image" {
  description = "Marketplace image used by banner mode and by the probe."
  type        = string
  default     = "ubuntu_noble"
}

variable "bastion_type" {
  description = "Commercial type of each Wallix instance."
  type        = string
  default     = "DEV1-L"
}

variable "probe_type" {
  description = "Commercial type of the probe."
  type        = string
  default     = "DEV1-S"
}

variable "lb_type" {
  description = "Load Balancer commercial type."
  type        = string
  default     = "LB-S"
}

variable "subnet" {
  description = "IPv4 subnet of the lab Private Network. Must not overlap the landing zone defaults."
  type        = string
  default     = "172.16.80.0/24"

  validation {
    condition = can(cidrhost(var.subnet, 20)) && alltrue([
      for other in ["172.16.0.0/24", "10.0.4.0/24", "10.0.5.0/24", "10.255.0.0/24", "10.64.0.0/10"] :
      !(
        sum([for i, octet in split(".", cidrhost(var.subnet, 0)) : tonumber(octet) * pow(256, 3 - i)]) <= sum([for i, octet in split(".", cidrhost(other, -1)) : tonumber(octet) * pow(256, 3 - i)]) &&
        sum([for i, octet in split(".", cidrhost(other, 0)) : tonumber(octet) * pow(256, 3 - i)]) <= sum([for i, octet in split(".", cidrhost(var.subnet, -1)) : tonumber(octet) * pow(256, 3 - i)])
      )
    ])
    error_message = "subnet must contain hosts .10 to .20 and must not overlap 172.16.0.0/24, 10.0.4.0/24, 10.0.5.0/24, 10.255.0.0/24 or 10.64.0.0/10."
  }
}

variable "admin_cidrs" {
  description = "Public IPv4 CIDRs allowed to SSH to the probe, and to the bastion admin ports when expose_bastion_admin is set."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : can(cidrhost(cidr, 0)) && cidr != "0.0.0.0/0"])
    error_message = "admin_cidrs must contain valid CIDRs other than 0.0.0.0/0."
  }
}

variable "expose_bastion_admin" {
  description = "Attach a public IP to each bastion and allow TCP 443 and 2242 from admin_cidrs. The load balancer stays private. Use this only to reach the Wallix wizard when the private NIC stays unconfigured."
  type        = bool
  default     = false
}

variable "recordings_filesystem" {
  description = "Create a Scaleway File Storage filesystem for session recordings. It is not attached to the appliances."
  type        = bool
  default     = false
}

variable "recordings_size_gb" {
  description = "Size of the optional recordings filesystem."
  type        = number
  default     = 100

  validation {
    condition     = var.recordings_size_gb >= 1
    error_message = "recordings_size_gb must be at least 1."
  }
}

variable "tags" {
  description = "Tags applied to the lab resources."
  type        = list(string)
  default     = ["wallix-ha"]
}

# Landing zone: the DSI hub (central firewall HA, egress, hybrid connectivity)
# and one project per department, in one root module and one state.
# Inputs: terraform.tfvars (see terraform.tfvars.example).
#
#   cp terraform.tfvars.example terraform.tfvars   # then adapt
#   terraform init -backend-config="bucket=$STATE_BUCKET" && terraform apply

terraform {
  required_version = ">= 1.10"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.86"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Bucket passed at init (-backend-config). Credentials: AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY set to Scaleway Object Storage keys.
  backend "s3" {
    key          = "landing-zone/terraform.tfstate"
    region       = "fr-par"
    endpoints    = { s3 = "https://s3.fr-par.scw.cloud" }
    use_lockfile = true

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

# Credentials: SCW_ACCESS_KEY / SCW_SECRET_KEY / SCW_DEFAULT_ORGANIZATION_ID
# (organization-wide API key).
provider "scaleway" {
  region = "fr-par"
  zone   = "fr-par-1"
}

module "hub" {
  source = "./modules/hub"

  name                  = var.name
  project_id            = var.project_id
  tags                  = var.tags
  cidrs                 = var.cidrs
  dept_supernet         = var.dept_supernet
  egress                = var.egress
  policy                = var.policy
  admin_cidrs           = var.admin_cidrs
  admin_ssh_public_keys = var.admin_ssh_public_keys
  firewall              = var.firewall
  vpn                   = var.vpn
  interlink             = var.interlink
}

module "department" {
  source   = "./modules/department"
  for_each = var.departments

  name                = each.key
  index               = each.value.index
  hybrid_bypass       = each.value.hybrid_bypass
  nacl_inbound        = each.value.nacl_inbound
  hub                 = module.hub.department_contract
  iam_permission_sets = var.iam_permission_sets
}

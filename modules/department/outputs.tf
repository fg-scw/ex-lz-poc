output "project_id" {
  value = scaleway_account_project.this.id
}

output "cidrs" {
  value = { pub = local.pub_cidr, private = local.private_cidr }
}

output "private_network_ids" {
  value = {
    pub     = scaleway_vpc_private_network.pub.id
    private = scaleway_vpc_private_network.private.id
  }
}

output "iam_group_id" {
  value = scaleway_iam_group.this.id
}

output "hybrid_bypass" {
  value = local.bypass
}

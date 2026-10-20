# terraform test - offline, no Scaleway API call.
mock_provider "scaleway" {}

variables {
  name  = "genomic"
  index = 0
  hub = {
    hub_vpc_id       = "fr-par/11111111-1111-1111-1111-111111111111"
    hybrid_vpc_id    = "fr-par/22222222-2222-2222-2222-222222222222"
    department_pools = { pub = "10.64.0.0/12", private = "10.96.0.0/11" }
    interlink_cidrs  = ["192.168.0.0/16"]
  }
}

run "slot_zero_without_bypass" {
  command = plan

  assert {
    condition     = output.cidrs.pub == "10.64.0.0/22" && output.cidrs.private == "10.96.0.0/21"
    error_message = "Index 0 must map to the first slot of each pool."
  }

  assert {
    condition     = length(scaleway_vpc_connector.private_to_hybrid) == 0 && length(scaleway_vpc_route.private_to_onprem) == 0
    error_message = "No hybrid resources without hybrid_bypass."
  }
}

run "slot_five_with_bypass" {
  command = plan

  variables {
    name          = "rh"
    index         = 5
    hybrid_bypass = true
    nacl_inbound  = [{ to = "private", source = "192.168.0.0/16", port = 5432 }]
  }

  assert {
    condition     = output.cidrs.pub == "10.64.20.0/22" && output.cidrs.private == "10.96.40.0/21"
    error_message = "Index 5 must map to the sixth /22 and /21."
  }

  assert {
    condition     = length(scaleway_vpc_connector.hybrid_to_private) == 1 && length(scaleway_vpc_route.private_to_onprem) == 1
    error_message = "hybrid_bypass must peer Private with Hybrid and route on-prem through it."
  }

  assert {
    condition     = length(scaleway_vpc_acl.this["pub"].rules) == 6 && length(scaleway_vpc_acl.this["private"].rules) == 7
    error_message = "NACLs: 6 baseline rules on Pub; 5 baseline + 1 bypass + 1 inbound on Private."
  }

  assert {
    condition = anytrue([for r in scaleway_vpc_acl.this["private"].rules :
    r.source == "192.168.0.0/16" && r.destination == "10.96.40.0/21" && r.dst_port_low == 5432 && r.dst_port_high == 5432])
    error_message = "nacl_inbound must open the declared port on the department Private CIDR."
  }

  assert {
    condition     = scaleway_vpc_acl.this["pub"].default_policy == "drop" && scaleway_account_project.this.name == "dept-rh"
    error_message = "Default-deny NACL and the dept- resource prefix are expected."
  }
}

run "bypass_needs_interlink" {
  command = plan

  variables {
    hybrid_bypass = true
    hub = {
      hub_vpc_id       = "fr-par/11111111-1111-1111-1111-111111111111"
      hybrid_vpc_id    = "fr-par/22222222-2222-2222-2222-222222222222"
      department_pools = { pub = "10.64.0.0/12", private = "10.96.0.0/11" }
      interlink_cidrs  = []
    }
  }

  assert {
    condition     = output.hybrid_bypass == false
    error_message = "Without Interlink there is nothing to bypass to."
  }
}

run "index_out_of_range_rejected" {
  command = plan

  variables {
    index = 1024
  }

  expect_failures = [var.index]
}

run "invalid_nacl_rule_rejected" {
  command = plan

  variables {
    nacl_inbound = [{ to = "dmz", source = "10.0.0.0/8" }]
  }

  expect_failures = [var.nacl_inbound]
}

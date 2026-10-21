# terraform test - offline, plan only, no Scaleway API call.
mock_provider "scaleway" {
  # The provider validates ID formats, so mocks need realistic IDs.
  mock_resource "scaleway_account_project" {
    defaults = { id = "44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_private_network" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_connector" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_customer_gateway" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_routing_policy" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_gateway" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_iam_application" {
    defaults = { id = "44444444-4444-4444-4444-444444444444" }
  }
}

variables {
  interlink = {
    pop_id         = "fr-par/66666666-6666-6666-6666-666666666666"
    bandwidth_mbps = 1000
    partner_id     = "fr-par/77777777-7777-7777-7777-777777777777"
    onprem_cidrs   = ["192.168.0.0/16"]
  }
  departments = {
    genomic = { index = 0 }
    rh = {
      index         = 5
      hybrid_bypass = true
      nacl_inbound  = [{ to = "private", source = "192.168.0.0/16", port = 5432 }]
    }
  }
}

run "departments_and_bypass" {
  command = plan

  assert {
    condition = alltrue([
      output.departments["genomic"].cidrs.pub == "10.64.0.0/22",
      output.departments["genomic"].cidrs.private == "10.96.0.0/21",
      output.departments["rh"].cidrs.pub == "10.64.20.0/22",
      output.departments["rh"].cidrs.private == "10.96.40.0/21",
    ])
    error_message = "Department CIDRs must be carved from the hub pools by index."
  }

  assert {
    condition = alltrue([
      output.departments["genomic"].hybrid_bypass == false,
      output.departments["rh"].hybrid_bypass == true,
    ])
    error_message = "Only the department with hybrid_bypass (and an Interlink) gets the Interlink peering and route."
  }
}

run "vpn_only" {
  command = plan

  variables {
    interlink = null
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["192.168.0.0/16"]
    }
    departments = { genomic = { index = 0 } }
  }

  assert {
    condition     = output.vpn != null && output.interlink == null
    error_message = "A VPN alone is a valid configuration."
  }
}

run "duplicate_index_rejected" {
  command = plan

  variables {
    departments = {
      genomic = { index = 3 }
      rh      = { index = 3 }
    }
  }

  expect_failures = [var.departments]
}

run "bypass_without_interlink_rejected" {
  command = plan

  variables {
    interlink = null
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["192.168.0.0/16"]
    }
  }

  expect_failures = [var.departments]
}

# terraform test - offline, plan only (the hub has local-exec provisioners that must never run).
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
  mock_resource "scaleway_ipam_ip" {
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
  mock_resource "scaleway_instance_server" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_public_gateway" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_public_gateway_ip" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_gateway" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_iam_application" {
    defaults = { id = "44444444-4444-4444-4444-444444444444" }
  }
}

mock_provider "random" {
  override_during = plan
  mock_resource "random_password" {
    defaults = { result = "test-password", bcrypt_hash = "$2a$10$test" }
  }
}

# The failover API key ends up in opnsense_secrets: known at plan time here.
override_resource {
  target          = module.hub.scaleway_iam_api_key.fw_failover
  override_during = plan
  values          = { secret_key = "11111111-1111-1111-1111-111111111111" }
}

variables {
  admin_cidrs           = ["203.0.113.10/32"]
  admin_ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest admin"]
  firewall = {
    nodes = {
      fw1 = { zone = "fr-par-1", image = "opnsense-central-fw" }
      fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
    }
  }
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
  }

  expect_failures = [var.departments]
}

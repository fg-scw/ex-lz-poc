# terraform test - offline, no Scaleway API call.
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
  mock_resource "scaleway_interlink_routing_policy" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
}

# Distinct connector IDs, known at plan time, to check which one a route targets.
override_resource {
  target          = scaleway_vpc_connector.hub_to_egress
  override_during = plan
  values          = { id = "fr-par/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
}

override_resource {
  target          = scaleway_vpc_connector.hub_to_hybrid
  override_during = plan
  values          = { id = "fr-par/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" }
}

variables {
  vpn = {
    customer_gateway_ip = "198.51.100.1"
    customer_asn        = 65010
    onprem_cidrs        = ["192.168.0.0/16"]
  }
}

run "vpn_only_is_the_path" {
  command = plan

  assert {
    condition     = output.department_contract.department_pools.pub == "10.64.0.0/12" && output.department_contract.department_pools.private == "10.96.0.0/11"
    error_message = "Department pools must be carved from the supernet."
  }

  assert {
    condition     = scaleway_vpc.this["hub"].enable_transitivity && !scaleway_vpc.this["egress"].enable_transitivity && !scaleway_vpc.this["hybrid"].enable_transitivity
    error_message = "Only the Hub VPC is transitive."
  }

  assert {
    condition     = scaleway_vpc_route.hub_default.destination == "0.0.0.0/0" && scaleway_vpc_route.hub_default.nexthop_vpc_connector_id == "fr-par/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    error_message = "With a VPN only, the Hub default route must go to the Egress connector."
  }

  assert {
    condition     = length(scaleway_vpc_connector.hub_to_hybrid) == 0 && length(scaleway_vpc_route.hybrid_to_departments) == 0
    error_message = "No Hub <-> Hybrid peering without an Interlink."
  }

  assert {
    condition     = scaleway_vpc_route.egress_to_departments.destination == "10.64.0.0/10"
    error_message = "Egress must route the department supernet to the Hub."
  }

  assert {
    condition = alltrue([
      toset(scaleway_s2s_vpn_routing_policy.this[0].prefix_filter_in) == toset(["0.0.0.0/0", "192.168.0.0/16"]),
      toset(scaleway_s2s_vpn_routing_policy.this[0].prefix_filter_out) == toset(["10.64.0.0/10", "10.0.4.0/24"]),
    ])
    error_message = "The VPN accepts the default route and announces the department supernet when it is the path."
  }

  assert {
    condition     = length(scaleway_interlink_routing_policy.this) == 0 && output.department_contract.interlink_cidrs == []
    error_message = "No Interlink resources without interlink."
  }
}

run "interlink_is_the_path" {
  command = plan

  variables {
    interlink = {
      pop_id         = "fr-par/66666666-6666-6666-6666-666666666666"
      bandwidth_mbps = 1000
      partner_id     = "fr-par/77777777-7777-7777-7777-777777777777"
      onprem_cidrs   = ["10.10.0.0/16"]
    }
  }

  assert {
    condition     = scaleway_vpc_route.hub_default.nexthop_vpc_connector_id == "fr-par/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    error_message = "With an Interlink, the Hub default route must go to the Hybrid connector."
  }

  assert {
    condition     = scaleway_vpc_route.hybrid_to_departments[0].destination == "10.64.0.0/10"
    error_message = "Hybrid must route the department supernet to the Hub."
  }

  assert {
    condition = alltrue([
      toset(scaleway_interlink_routing_policy.this[0].prefix_filter_in) == toset(["0.0.0.0/0", "10.10.0.0/16"]),
      toset(scaleway_interlink_routing_policy.this[0].prefix_filter_out) == toset(["10.64.0.0/10", "10.0.5.0/24"]),
      toset(scaleway_s2s_vpn_routing_policy.this[0].prefix_filter_in) == toset(["0.0.0.0/0", "192.168.0.0/16"]),
      toset(scaleway_s2s_vpn_routing_policy.this[0].prefix_filter_out) == toset(["10.0.4.0/24"]),
    ])
    error_message = "Only the Interlink announces the department supernet; the VPN announces its own VPC CIDR."
  }

  assert {
    condition     = toset(output.department_contract.interlink_cidrs) == toset(["10.10.0.0/16"])
    error_message = "The contract must carry the Interlink on-prem CIDRs."
  }
}

run "interlink_only" {
  command = plan

  variables {
    vpn = null
    interlink = {
      pop_id         = "fr-par/66666666-6666-6666-6666-666666666666"
      bandwidth_mbps = 1000
      partner_id     = "fr-par/77777777-7777-7777-7777-777777777777"
      onprem_cidrs   = ["10.10.0.0/16"]
    }
  }

  assert {
    condition     = length(scaleway_s2s_vpn_gateway.this) == 0 && length(scaleway_vpc_connector.hub_to_hybrid) == 1
    error_message = "An Interlink alone is a valid configuration."
  }
}

run "rejects_no_link" {
  command = plan

  variables {
    vpn = null
  }

  expect_failures = [var.interlink]
}

run "vpn_zones_default_and_override" {
  command = plan

  assert {
    condition     = scaleway_s2s_vpn_gateway.this["a"].zone == "fr-par-1" && scaleway_s2s_vpn_gateway.this["b"].zone == "fr-par-2" && scaleway_s2s_vpn_connection.this["b"].bgp_config_ipv4[0].private_ip == "169.254.100.5/30"
    error_message = "One VPN gateway per zone (fr-par-1, fr-par-2 by default), with distinct BGP /30."
  }
}

run "vpn_zones_override" {
  command = plan

  variables {
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["192.168.0.0/16"]
      zones               = { b = "fr-par-3" }
    }
  }

  assert {
    condition     = scaleway_s2s_vpn_gateway.this["a"].zone == "fr-par-1" && scaleway_s2s_vpn_gateway.this["b"].zone == "fr-par-3"
    error_message = "vpn.zones must override the zone of one gateway."
  }
}

# The root module forwards unset options as null: null must mean the default.
run "null_means_default" {
  command = plan

  variables {
    name          = null
    tags          = null
    cidrs         = null
    dept_supernet = null
  }

  assert {
    condition     = output.department_contract.department_pools.pub == "10.64.0.0/12" && scaleway_account_project.this[0].name == "dsi-hub"
    error_message = "Null options must fall back to the module defaults."
  }
}

run "vpn_ciphers" {
  command = plan

  variables {
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["192.168.0.0/16"]
      ciphers             = { esp = { encryption = "aes128", dh_group = "modp3072" } }
    }
  }

  assert {
    condition = alltrue([
      scaleway_s2s_vpn_connection.this["a"].esp_ciphers[0].encryption == "aes128",
      scaleway_s2s_vpn_connection.this["a"].esp_ciphers[0].dh_group == "modp3072",
      scaleway_s2s_vpn_connection.this["a"].esp_ciphers[0].integrity == "sha256",
      scaleway_s2s_vpn_connection.this["a"].ikev2_ciphers[0].encryption == "aes256",
      scaleway_s2s_vpn_connection.this["a"].ikev2_ciphers[0].dh_group == "modp2048",
    ])
    error_message = "vpn.ciphers must override the proposals, the others keep the defaults."
  }
}

run "rejects_overlap_with_onprem" {
  command = plan

  variables {
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["10.64.8.0/22"]
    }
  }

  expect_failures = [var.dept_supernet]
}

run "rejects_overlap_between_dsi_networks" {
  command = plan

  variables {
    cidrs = { hub = "10.64.1.0/24" }
  }

  expect_failures = [var.dept_supernet]
}

run "inter_department_drop" {
  command = plan

  assert {
    condition = scaleway_vpc_acl.hub.default_policy == "accept" && length(scaleway_vpc_acl.hub.rules) == 1 && alltrue([
      for r in scaleway_vpc_acl.hub.rules :
      r.action == "drop" && r.protocol == "ANY" && r.source == "10.64.0.0/10" && r.destination == "10.64.0.0/10" &&
      r.src_port_low == 0 && r.src_port_high == 65535 && r.dst_port_low == 0 && r.dst_port_high == 65535
    ])
    error_message = "The hub ACL must accept by default and drop dept_supernet to dept_supernet on all ports, once."
  }
}

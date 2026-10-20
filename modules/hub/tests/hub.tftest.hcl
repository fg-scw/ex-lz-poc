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
  target          = scaleway_iam_api_key.fw_failover
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
  vpn = {
    customer_gateway_ip = "198.51.100.1"
    customer_asn        = 65010
    onprem_cidrs        = ["192.168.0.0/16"]
  }
}

run "address_plan_and_ingress" {
  command = plan

  assert {
    condition     = output.department_contract.department_pools.pub == "10.64.0.0/12" && output.department_contract.department_pools.private == "10.96.0.0/11"
    error_message = "Department pools must be carved from the supernet."
  }

  assert {
    condition     = toset(keys(scaleway_vpc_ingress_rule.to_firewall)) == toset(["10.64.0.0/10", "10.0.4.0/24", "192.168.0.0/16"])
    error_message = "Hub ingress rules: department supernet, DSI egress and VPN on-prem, nothing per department."
  }

  assert {
    condition     = alltrue([for r in scaleway_vpc_ingress_rule.to_firewall : r.nexthop_resource_ip == "172.16.0.10"])
    error_message = "Ingress rules must target the hub data VIP."
  }

  assert {
    condition     = scaleway_vpc_public_gateway.egress["a"].zone == "fr-par-1" && scaleway_vpc_public_gateway.egress["b"].zone == "fr-par-2"
    error_message = "One Public Gateway per firewall zone."
  }

  assert {
    condition     = scaleway_s2s_vpn_gateway.this["a"].zone == "fr-par-1" && scaleway_s2s_vpn_gateway.this["b"].zone == "fr-par-2" && scaleway_s2s_vpn_connection.this["b"].bgp_config_ipv4[0].private_ip == "169.254.100.5/30"
    error_message = "One VPN gateway and tunnel per firewall zone, with distinct BGP /30."
  }

  assert {
    condition     = scaleway_ipam_ip.fw_vip["hub"].address == "172.16.0.9" && scaleway_ipam_ip.data_vip["hub"].address == "172.16.0.10" && scaleway_ipam_ip.data_vip["egress"].address == "10.0.4.10"
    error_message = "CARP election VIP (.9, virtual MAC) must not collide with the IPAM data VIPs (.10)."
  }

  assert {
    condition     = output.department_contract.interlink_cidrs == []
    error_message = "No Interlink means no bypass CIDR."
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
    egress        = null
  }

  assert {
    condition     = output.department_contract.department_pools.pub == "10.64.0.0/12" && scaleway_ipam_ip.data_vip["hub"].address == "172.16.0.10" && scaleway_account_project.this[0].name == "dsi-hub"
    error_message = "Null options must fall back to the module defaults."
  }
}

run "bootstrap_config" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<synchronizetoip/>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<password>@@ROOT_HASH@@</password>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw2"].user_data["opnsense_config"]), "<advskew>100</advskew>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<content>10.64.0.0/10</content>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<network>192.168.0.0/16</network>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw2"].user_data["opnsense_config"]), "<target>10.0.4.10</target>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<subnet>172.16.0.9</subnet>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<disablepreempt>1</disablepreempt>"),
      length(regexall("<statetype>sloppy state</statetype>", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]))) == 5,
      can(regex("(?s)<statetype>sloppy state</statetype>\\s*<descr>\\[OUT\\][^<]*</descr>\\s*<direction>out</direction>\\s*<floating>yes</floating>\\s*<interface>lan,opt2</interface>\\s*<quick>1</quick>", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]))),
      strcontains(base64decode(scaleway_instance_server.fw["fw2"].user_data["opnsense_config"]), "<peer>172.16.0.11</peer>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<gateway>10.0.4.3</gateway>"),
    ])
    error_message = "Rendered OPNsense config does not match the HA roles or the address plan."
  }

  assert {
    condition = alltrue([for k in ["fw1", "fw2"] : alltrue([
      !strcontains(base64decode(scaleway_instance_server.fw[k].user_data["opnsense_config"]), "$2a$"),
      !strcontains(base64decode(scaleway_instance_server.fw[k].user_data["opnsense_config"]), "test-password"),
      strcontains(scaleway_instance_server.fw[k].user_data["opnsense_secrets"], "ROOT_HASH='$2a$10$test'"),
      can(regex("^[0-9a-f]{64}$", scaleway_instance_server.fw[k].user_data["opnsense_platform"])),
    ])])
    error_message = "Secrets must travel only in opnsense_secrets; the configuration holds tokens and a platform hash."
  }
}

run "failover_hook" {
  command = plan

  variables {
    project_id = "55555555-5555-5555-5555-555555555555"
  }

  override_resource {
    target          = scaleway_vpc_public_gateway_ip.egress
    override_during = plan
    values          = { address = "198.51.100.7" }
  }

  assert {
    condition = alltrue([
      toset(scaleway_iam_policy.fw_failover.rule[0].permission_set_names) == toset(["IPAMFullAccess"]),
      toset(scaleway_iam_policy.fw_failover.rule[0].project_ids) == toset(["55555555-5555-5555-5555-555555555555"]),
      scaleway_iam_policy.fw_failover.rule[0].condition == "request.ip == \"198.51.100.7\" || request.ip == \"198.51.100.7\"",
      toset(keys(scaleway_instance_user_data.scwlz)) == toset(["fw1", "fw2"]),
      scaleway_instance_user_data.scwlz["fw1"].key == "scwlz",
    ])
    error_message = "The failover key must be IPAM-only, DSI-project-only, usable only from the egress PGWs, and each node gets its failover settings."
  }
}

run "policy_change_keeps_platform" {
  command = plan

  variables {
    dept_supernet = "10.128.0.0/10"
  }

  assert {
    condition     = scaleway_instance_server.fw["fw1"].user_data["opnsense_platform"] == run.bootstrap_config.firewall.nodes.fw1.platform_hash
    error_message = "A policy-only change (department supernet in aliases and routes) must not change the platform hash."
  }
}

run "customer_root_hash" {
  command = plan

  variables {
    firewall = {
      root_password_hash = "$2y$10$abcdefghijklmnopqrstuuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
      nodes = {
        fw1 = { zone = "fr-par-1", image = "opnsense-central-fw" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  assert {
    condition     = strcontains(scaleway_instance_server.fw["fw1"].user_data["opnsense_secrets"], "ROOT_HASH='$2y$10$abcdefghijklmnopqrstuuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'") && output.fw_root_password == null
    error_message = "A customer bcrypt hash replaces the generated password."
  }
}

run "rejects_image_and_volume" {
  command = plan

  variables {
    firewall = {
      nodes = {
        fw1 = { zone = "fr-par-1", image = "opnsense-central-fw", volume_id = "fr-par-1/x" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  expect_failures = [var.firewall]
}

run "existing_project_and_snapshot" {
  command = plan

  variables {
    project_id = "55555555-5555-5555-5555-555555555555"
    firewall = {
      nodes = {
        fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/66666666-6666-6666-6666-666666666666" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  assert {
    condition     = length(scaleway_account_project.this) == 0 && output.project_id == "55555555-5555-5555-5555-555555555555"
    error_message = "An existing project must be used as is."
  }

  assert {
    condition     = length(scaleway_block_volume.fw) == 1 && scaleway_block_volume.fw["fw1"].zone == "fr-par-1" && scaleway_instance_server.fw["fw1"].boot_type == "local"
    error_message = "A snapshot node boots from a fresh local volume in its zone."
  }
}

run "custom_policy_keeps_platform" {
  command = plan

  variables {
    policy = {
      aliases = { GENOMIC = ["10.64.0.0/22"], HR = ["10.64.4.0/22"] }
      rules = [{
        description = "Genomic reaches HR on 443"
        action      = "pass"
        source      = "GENOMIC"
        destination = "HR"
        protocol    = "tcp"
        port        = 443
        state       = "keep"
        }, {
        description = "Partner network reaches genomic"
        action      = "pass"
        source      = "192.0.2.0/24"
        destination = "GENOMIC"
      }]
      nat_outbound = [{ description = "Genomic SNAT", source = "GENOMIC" }]
    }
  }

  assert {
    condition = alltrue([
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<name>GENOMIC</name>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<content>10.64.4.0/22</content>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<descr>Genomic reaches HR on 443</descr>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<destination><network>HR</network><port>443</port></destination>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<descr>Genomic SNAT</descr>"),
      # A literal CIDR is an <address>, an alias a <network>.
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<source><address>192.0.2.0/24</address></source>"),
      # Customer rules precede the default inter-department block.
      index(split("\n", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"])), "      <descr>Genomic reaches HR on 443</descr>") < index(split("\n", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"])), "      <descr>[EW] SRC=DEPT_NETS DST=DEPT_NETS ACT=BLOCK (inter-department, add explicit exceptions above)</descr>"),
    ])
    error_message = "A custom alias, rule and SNAT rule must be rendered, the rule before the default [EW] block."
  }

  assert {
    condition     = scaleway_instance_server.fw["fw1"].user_data["opnsense_platform"] == run.bootstrap_config.firewall.nodes.fw1.platform_hash
    error_message = "Policy changes (rules, aliases, NAT) must not change the platform hash."
  }
}

run "parameters_flow_through" {
  command = plan

  variables {
    tags = ["acme"]
    firewall = {
      disk             = { size_gb = 40, iops = 15000 }
      hosts            = { election = 20, data = 21, fw1 = 22, fw2 = 23 }
      system           = { timezone = "Europe/Brussels", dns = ["9.9.9.9", "8.8.8.8"], ntp = ["ntp.example.org"] }
      gateway_monitors = { a = "8.8.8.8", b = "8.8.4.4" }
      nodes = {
        fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/66666666-6666-6666-6666-666666666666" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
    egress = { gateway_type = "VPC-GW-M", pgw_hosts = { a = 5, b = 6 } }
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["192.168.0.0/16"]
      bgp_links           = { b = { scaleway = "169.254.101.1/30", onprem = "169.254.101.2/30" } }
    }
  }

  assert {
    condition = alltrue([
      scaleway_ipam_ip.fw_vip["hub"].address == "172.16.0.20" && scaleway_ipam_ip.fw_vip["hub"].custom_resource[0].mac_address == "00:00:5e:00:01:0a",
      scaleway_ipam_ip.data_vip["hub"].address == "172.16.0.21" && scaleway_ipam_ip.data_vip["egress"].address == "10.0.4.21",
      scaleway_ipam_ip.fw["fw2-hub"].address == "172.16.0.23",
      scaleway_ipam_ip.egress_pgw["a"].address == "10.0.4.5" && scaleway_ipam_ip.egress_pgw["b"].address == "10.0.4.6",
      scaleway_vpc_public_gateway.egress["a"].type == "VPC-GW-M",
      scaleway_block_volume.fw["fw1"].size_in_gb == 40 && scaleway_block_volume.fw["fw1"].iops == 15000,
      scaleway_instance_server.fw["fw1"].root_volume[0].size_in_gb == 40 && scaleway_instance_server.fw["fw1"].root_volume[0].sbs_iops == 15000,
      scaleway_vpc.this["hub"].tags == tolist(["acme"]),
      scaleway_s2s_vpn_connection.this["a"].bgp_config_ipv4[0].private_ip == "169.254.100.1/30",
      scaleway_s2s_vpn_connection.this["b"].bgp_config_ipv4[0].peer_private_ip == "169.254.101.2/30",
    ])
    error_message = "firewall.hosts, disk, egress, tags and vpn.bgp_links must reach the resources."
  }

  assert {
    condition = alltrue([
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<timezone>Europe/Brussels</timezone>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<dnsserver>9.9.9.9</dnsserver>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<dnsserver>8.8.8.8</dnsserver>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<timeservers>ntp.example.org</timeservers>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<monitor>8.8.4.4</monitor>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<gateway>10.0.4.6</gateway>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<subnet>172.16.0.20</subnet>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<peer>172.16.0.23</peer>"),
    ])
    error_message = "firewall.system, gateway_monitors, hosts and egress.pgw_hosts must reach the OPNsense configuration."
  }
}

run "rejects_colliding_hosts" {
  command = plan

  variables {
    egress = { pgw_hosts = { a = 11 } }
  }

  expect_failures = [var.firewall]
}

run "rejects_xml_in_description" {
  command = plan

  variables {
    policy = {
      rules = [{ description = "x</descr><rule>", action = "pass", source = "any", destination = "any" }]
    }
  }

  expect_failures = [var.policy]
}

run "rejects_unknown_alias" {
  command = plan

  variables {
    policy = {
      rules = [{ description = "Unknown alias", action = "pass", source = "NOPE", destination = "any" }]
    }
  }

  expect_failures = [var.policy]
}

run "secrets_are_sensitive" {
  command = plan

  assert {
    condition     = issensitive(scaleway_instance_server.fw["fw1"].user_data["opnsense_secrets"]) && !issensitive(scaleway_instance_server.fw["fw2"].user_data["opnsense_config"])
    error_message = "opnsense_secrets must be sensitive (plan and apply output); opnsense_config holds no secret and stays readable."
  }
}

run "no_syslog_by_default" {
  command = plan

  assert {
    condition     = !strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<Syslog")
    error_message = "Without firewall.syslog the configuration must hold no Syslog section."
  }
}

run "remote_syslog" {
  command = plan

  variables {
    firewall = {
      syslog = [{ host = "logs.example.org" }, { host = "10.0.9.5", port = 6514, transport = "tcp" }]
      nodes = {
        fw1 = { zone = "fr-par-1", image = "opnsense-central-fw" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  assert {
    condition = alltrue([
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<destination uuid=\"${uuidv5("dns", "scwlz-syslog/logs.example.org:514")}\">"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<transport>udp4</transport>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<hostname>logs.example.org</hostname>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<transport>tcp4</transport>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<port>6514</port>"),
      strcontains(base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]), "<loglocal>1</loglocal>"),
      length(regexall("<rfc5424>1</rfc5424>", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]))) == 2,
    ])
    error_message = "Each syslog entry must render one destination (udp4/tcp4, deterministic uuid, RFC 5424) and keep the local logs."
  }

  assert {
    condition     = scaleway_instance_server.fw["fw1"].user_data["opnsense_platform"] != run.bootstrap_config.firewall.nodes.fw1.platform_hash
    error_message = "Syslog is a platform setting: it changes the platform hash (rebuild the node)."
  }
}

run "rejects_bad_syslog_transport" {
  command = plan

  variables {
    firewall = {
      syslog = [{ host = "logs.example.org", transport = "http" }]
      nodes = {
        fw1 = { zone = "fr-par-1", image = "opnsense-central-fw" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  expect_failures = [var.firewall]
}

run "rejects_bad_syslog_port" {
  command = plan

  variables {
    firewall = {
      syslog = [{ host = "logs.example.org", port = 70000 }]
      nodes = {
        fw1 = { zone = "fr-par-1", image = "opnsense-central-fw" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  expect_failures = [var.firewall]
}

run "rejects_xml_in_syslog_host" {
  command = plan

  variables {
    firewall = {
      syslog = [{ host = "a</hostname><x>" }]
      nodes = {
        fw1 = { zone = "fr-par-1", image = "opnsense-central-fw" }
        fw2 = { zone = "fr-par-2", image = "opnsense-central-fw" }
      }
    }
  }

  expect_failures = [var.firewall]
}

run "internal_nets_cover_the_landing_zone" {
  command = plan

  variables {
    dept_supernet = "100.64.0.0/10"
    interlink = {
      pop_id         = "fr-par/66666666-6666-6666-6666-666666666666"
      bandwidth_mbps = 1000
      partner_id     = "fr-par/77777777-7777-7777-7777-777777777777"
      onprem_cidrs   = ["10.10.0.0/16"]
    }
  }

  # RFC1918, supernet, DSI networks (egress, hybrid, hub, sync), VPN and
  # Interlink on-prem; 192.168.0.0/16 (VPN) is already there: no duplicate.
  assert {
    condition = regex("(?s)<name>internal_nets</name>.*?<content>(.*?)</content>", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"]))[0] == join("\n", [
      "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
      "10.0.4.0/24", "172.16.0.0/24", "10.0.5.0/24", "10.255.0.0/24", "10.10.0.0/16",
    ])
    error_message = "internal_nets must hold RFC1918, the department supernet, the DSI networks and the on-prem ranges, once each."
  }
}

run "egress_rule_is_not_logged" {
  command = plan

  assert {
    condition = alltrue([
      strcontains([for c in split("</rule>", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"])) : c if strcontains(c, "[EGRESS]")][0], "<log>0</log>"),
      strcontains([for c in split("</rule>", base64decode(scaleway_instance_server.fw["fw1"].user_data["opnsense_config"])) : c if strcontains(c, "[EW]")][0], "<log>1</log>"),
    ])
    error_message = "[EGRESS] must not log every department session; the other rules keep logging."
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

run "failover_settings_name_the_peer" {
  command = plan

  override_resource {
    target          = scaleway_instance_private_nic.hub
    override_during = plan
    values          = { mac_address = "02:00:00:AA:00:01" }
  }

  override_resource {
    target          = scaleway_instance_private_nic.egress
    override_during = plan
    values          = { mac_address = "02:00:00:AA:00:02" }
  }

  override_resource {
    target          = scaleway_ipam_ip.data_vip
    override_during = plan
    values          = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }

  override_resource {
    target          = scaleway_vpc.this
    override_during = plan
    values          = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }

  assert {
    condition = alltrue([
      strcontains(scaleway_instance_user_data.scwlz["fw1"].value, "SYNC_IP='10.255.0.11'"),
      strcontains(scaleway_instance_user_data.scwlz["fw1"].value, "PEER_SYNC_IP='10.255.0.12'"),
      strcontains(scaleway_instance_user_data.scwlz["fw2"].value, "PEER_SYNC_IP='10.255.0.11'"),
      strcontains(scaleway_instance_user_data.scwlz["fw1"].value, "PEER_MACS='02:00:00:aa:00:01 02:00:00:aa:00:02'"),
    ])
    error_message = "Each node must learn its sync IP and the sync IP and (lower case) hub and egress MACs of its peer, for the split brain guard."
  }
}

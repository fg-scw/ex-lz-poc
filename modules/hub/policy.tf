# Firewall policy as data: the transit rules, aliases and SNAT rules rendered
# into the <filter>, <Alias> and <nat> sections of the configuration. Those
# sections are applied live by the nodes (see fw_platform_hash). The [MGMT] and
# [HA] rules are platform and stay in the template.

locals {
  rule_defaults = { protocol = "any", port = null, port_end = null, state = "sloppy", destination_not = false, log = true }

  # The rules of every landing zone. Customer rules (var.policy.rules) go
  # before them: the first quick rule that matches wins, so an exception to
  # the inter-department block must precede it.
  default_rules_start = [
    merge(local.rule_defaults, {
      uuid        = "a0000000-0000-0000-0000-000000000010", action = "block", interface = "hub", source = "DEPT_NETS", destination = "DEPT_NETS"
      description = "[EW] SRC=DEPT_NETS DST=DEPT_NETS ACT=BLOCK (inter-department, add explicit exceptions above)"
    }),
    merge(local.rule_defaults, {
      uuid        = "a0000000-0000-0000-0000-000000000020", action = "pass", interface = "hub", source = "DSI_EGRESS_NET", destination = "DEPT_NETS"
      description = "[DSI] SRC=DSI_EGRESS_NET DST=DEPT_NETS ACT=PASS (DSI LB / Edge Services)"
    }),
  ]

  default_rules_vpn = length(local.vpn_cidrs) == 0 ? [] : [
    merge(local.rule_defaults, {
      uuid        = "a0000000-0000-0000-0000-000000000030", action = "pass", interface = "hub", source = "ONPREM_VPN", destination = "DEPT_NETS"
      description = "[VPN] SRC=ONPREM_VPN DST=DEPT_NETS ACT=PASS"
    }),
    merge(local.rule_defaults, {
      uuid        = "a0000000-0000-0000-0000-000000000031", action = "pass", interface = "hub", source = "DEPT_NETS", destination = "ONPREM_VPN"
      description = "[VPN] SRC=DEPT_NETS DST=ONPREM_VPN ACT=PASS"
    }),
  ]

  default_rules_end = [
    merge(local.rule_defaults, {
      uuid        = "a0000000-0000-0000-0000-000000000040", action = "pass", interface = "hub", source = "DEPT_NETS", destination = "internal_nets", destination_not = true
      description = "[EGRESS] SRC=DEPT_NETS DST=INTERNET ACT=PASS"
      # One log line per department session would fill the disk and the Cockpit quota.
      log = false
    }),
  ]

  # Deterministic UUIDs (descriptions are unique, see the policy variable), so
  # a re-render only changes what the customer changed.
  user_rules = [
    for r in var.policy.rules : merge(r, { uuid = uuidv5("dns", "scwlz-rule/${r.description}"), destination_not = false, log = true })
  ]

  policy_rules = [
    for r in concat(local.user_rules, local.default_rules_start, local.default_rules_vpn, local.default_rules_end) : merge(r, {
      iface           = r.interface == "hub" ? "lan" : "opt2"
      source_xml      = local.endpoint_xml[r.source]
      destination_xml = "${local.endpoint_xml[r.destination]}${r.port == null ? "" : "<port>${r.port_end == null ? r.port : "${r.port}-${r.port_end}"}</port>"}"
    })
  ]

  # OPNsense rule endpoints: an alias or an interface network goes in
  # <network>, a literal CIDR in <address>.
  endpoint_xml = {
    for e in distinct(concat(
      [for r in concat(local.user_rules, local.default_rules_start, local.default_rules_vpn, local.default_rules_end) : r.source],
      [for r in concat(local.user_rules, local.default_rules_start, local.default_rules_vpn, local.default_rules_end) : r.destination],
      [for n in var.policy.nat_outbound : n.source],
      [for n in var.policy.nat_outbound : n.destination],
    )) : e => e == "any" ? "<any>1</any>" : can(cidrnetmask(e)) ? "<address>${e}</address>" : "<network>${e}</network>"
  }

  policy_aliases = {
    for name, cidrs in var.policy.aliases : name => { uuid = uuidv5("dns", "scwlz-alias/${name}"), cidrs = cidrs }
  }

  policy_nat = [
    for n in var.policy.nat_outbound : {
      description = n.description
      source      = local.endpoint_xml[n.source]
      destination = local.endpoint_xml[n.destination]
      target      = coalesce(n.target, local.data_vips.egress)
    }
  ]
}

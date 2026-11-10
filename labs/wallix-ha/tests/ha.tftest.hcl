# terraform test — no Scaleway API call.
mock_provider "scaleway" {
  mock_resource "scaleway_vpc" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_private_network" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_ipam_ip" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_instance_security_group" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_instance_ip" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_instance_server" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_instance_private_nic" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_lb" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_lb_backend" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_lb_frontend" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_file_filesystem" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
}

variables {
  admin_cidrs = ["203.0.113.10/32"]
}

run "wallix_active_passive_entry" {
  command = plan

  assert {
    condition     = scaleway_lb.this.assign_flexible_ip == false && scaleway_lb.this.assign_flexible_ipv6 == false
    error_message = "The load balancer must not publish a public address."
  }

  assert {
    condition     = scaleway_lb_backend.svc["rdp"].forward_port_algorithm == "first"
    error_message = "RDP backend must use the first algorithm."
  }

  assert {
    condition     = scaleway_lb_backend.svc["rdp"].server_ips == tolist(["172.16.80.11", "172.16.80.12"])
    error_message = "RDP backend must list the master before the slave."
  }

  assert {
    condition     = scaleway_lb_backend.svc["ssh"].forward_port == 22 && scaleway_lb_backend.svc["https"].forward_port == 443 && scaleway_lb_backend.svc["rdp"].forward_port == 3389
    error_message = "Backend ports must be 22, 443 and 3389."
  }

  assert {
    condition     = scaleway_lb_backend.svc["rdp"].health_check_port == 3389 && scaleway_lb_backend.svc["ssh"].health_check_port == 22 && scaleway_lb_backend.svc["https"].health_check_port == 443
    error_message = "Each health check must use the frontend port."
  }

  assert {
    condition     = scaleway_lb_backend.svc["rdp"].on_marked_down_action == "shutdown_sessions"
    error_message = "A dead node must drop its sessions."
  }

  assert {
    condition     = scaleway_lb_backend.svc["rdp"].max_connections == null
    error_message = "max_connections must stay unset so traffic cannot spill to the slave."
  }

  assert {
    condition     = scaleway_lb_backend.svc["rdp"].sticky_sessions == "none"
    error_message = "Sticky sessions must stay off."
  }

  assert {
    condition = alltrue([
      for key, frontend in scaleway_lb_frontend.svc :
      frontend.inbound_port == local.services[key] && frontend.inbound_port != 2242
    ])
    error_message = "Frontends are 22, 443 and 3389. Admin port 2242 stays off the load balancer."
  }

  assert {
    condition = (
      scaleway_instance_server.bastion["a"].image == "9a4410b3-f8b4-4aba-aab5-73447ce5710e" &&
      scaleway_instance_server.bastion["b"].image == "9a4410b3-f8b4-4aba-aab5-73447ce5710e" &&
      scaleway_instance_server.bastion["a"].enable_dynamic_ip == false &&
      scaleway_instance_server.bastion["a"].ip_id == null &&
      scaleway_instance_server.bastion["a"].zone == "fr-par-1"
    )
    error_message = "Wallix nodes use the fr-par-1 image, with no public IP and no cloud-init."
  }

  assert {
    condition     = length(scaleway_file_filesystem.recordings) == 0
    error_message = "File Storage stays off unless recordings_filesystem is set."
  }

  assert {
    condition     = output.lb_private_ip == "172.16.80.10" && output.bastion_ips.a == "172.16.80.11" && output.bastion_ips.b == "172.16.80.12"
    error_message = "Reserved addresses must keep the master in front of the slave."
  }
}

run "banner_identifies_nodes" {
  command = plan

  variables {
    mode = "banner"
  }

  assert {
    condition = (
      scaleway_instance_server.bastion["a"].image == "ubuntu_noble" &&
      strcontains(scaleway_instance_server.bastion["a"].user_data["cloud-init"], "banner-node:a") &&
      strcontains(scaleway_instance_server.bastion["b"].user_data["cloud-init"], "banner-node:b")
    )
    error_message = "Banner mode must boot Ubuntu listeners that identify a and b."
  }
}

run "admin_public_ip_and_recordings" {
  command = plan

  variables {
    expose_bastion_admin  = true
    recordings_filesystem = true
  }

  assert {
    condition = (
      length(scaleway_instance_ip.bastion) == 2 &&
      length(scaleway_file_filesystem.recordings) == 1 &&
      length(scaleway_instance_server.bastion["a"].filesystems) == 0
    )
    error_message = "A public admin IP and a standalone recordings filesystem must not attach virtio-fs to the appliance."
  }
}

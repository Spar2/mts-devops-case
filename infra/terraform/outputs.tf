output "vm_ip" {
  description = "IPv4-адрес ВМ из DHCP-аренды сети libvirt default."
  value       = libvirt_domain.sensor.network_interface[0].addresses[0]
}

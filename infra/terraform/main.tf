provider "libvirt" {
  uri = var.libvirt_uri
}

locals {
  # Поток release, не daily. Имя файла стабильное, содержимое — текущий point-release 24.04.
  ubuntu_image_url = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  disk_bytes       = 30 * 1024 * 1024 * 1024 # 30 GiB
  # filebase64 читает ключ только если путь задан. Пустая строка — публичный HTTPS clone.
  github_deploy_key_b64 = var.github_deploy_key_path == "" ? "" : sensitive(filebase64(var.github_deploy_key_path))
}

resource "libvirt_volume" "base" {
  name   = "mts-sensor-ubuntu-24.04.qcow2"
  pool   = "default"
  source = local.ubuntu_image_url
}

resource "libvirt_volume" "root" {
  name           = "mts-sensor-root.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base.id
  size           = local.disk_bytes
}

resource "libvirt_cloudinit_disk" "sensor" {
  name = "mts-sensor-cloudinit.iso"
  pool = "default"
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    repo_url              = var.repo_url
    github_deploy_key_b64 = local.github_deploy_key_b64
    ssh_public_key        = var.ssh_public_key
    run_make_up           = var.run_make_up
  })
  network_config = file("${path.module}/../cloud-init/network-config.yaml")
  meta_data = yamlencode({
    "instance-id"    = "mts-sensor"
    "local-hostname" = "mts-sensor"
  })
}

resource "libvirt_domain" "sensor" {
  name      = "mts-sensor"
  vcpu      = var.vm_vcpu
  memory    = var.vm_memory_mib
  cloudinit = libvirt_cloudinit_disk.sensor.id
  autostart = true

  disk {
    volume_id = libvirt_volume.root.id
  }

  network_interface {
    network_name   = "default"
    hostname       = "mts-sensor"
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

variable "repo_url" {
  description = "URL репозитория для clone на ВМ. По умолчанию публичный HTTPS без секрета. С github_deploy_key_path нужен SSH URL (git@github.com:org/repo.git или ssh://)."
  type        = string
  default     = "https://github.com/Spar2/mts-devops-case.git"
}

variable "github_deploy_key_path" {
  description = "Необязательный абсолютный путь на хосте Terraform к приватному deploy-key (OpenSSH). Пустая строка — clone repo_url по HTTPS без секрета. Ключ не коммитить. cloud-init удаляет файл ключа с ВМ после clone."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.github_deploy_key_path == "" || (startswith(var.github_deploy_key_path, "/") && !strcontains(var.github_deploy_key_path, "\n"))
    error_message = "github_deploy_key_path — абсолютный путь без перевода строки, либо пустая строка."
  }
}

variable "ssh_public_key" {
  description = "Публичный SSH-ключ пользователя ubuntu на ВМ. Пустая строка — ключ не добавляется."
  type        = string
  default     = ""
}

variable "libvirt_uri" {
  description = "URI подключения к libvirt."
  type        = string
  default     = "qemu:///system"
}

variable "vm_vcpu" {
  description = "vCPU ВМ"
  type        = number
  default     = 4
}

variable "vm_memory_mib" {
  description = "RAM ВМ в МиБ (8 ГиБ по умолчанию; kube-prometheus-stack + k3s укладываются в 6 ГиБ)"
  type        = number
  default     = 8192
}

variable "run_make_up" {
  description = "После клона запустить в госте make up K3D=0. false — только пакеты, пользователь ubuntu и клон (малая ВМ без k3s)."
  type        = bool
  default     = true
}

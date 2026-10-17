variable "repo_url" {
  description = "HTTPS URL репозитория. cloud-init клонирует его на ВМ."
  type        = string
  default     = "https://github.com/Spar2/mts-devops-case.git"
}

variable "github_token" {
  description = "Токен GitHub для приватного репозитория. Пустая строка — clone без токена. Не коммитить."
  type        = string
  sensitive   = true
  default     = ""
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

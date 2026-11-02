variable "subscription_id" {
  description = "Assinatura Azure que vai conter a VM do ZISP."
  type        = string
}

variable "location" {
  description = "Região. brazilsouth: os Mikrotik e o banco do ZISP estão no Brasil."
  type        = string
  default     = "brazilsouth"
}

variable "resource_group_name" {
  description = "Resource group. O Terraform CRIA este RG -- use um nome que não exista."
  type        = string
  default     = "zisp-sb_group"
}

variable "vm_name" {
  type    = string
  default = "zisp-sb"
}

variable "vm_size" {
  description = "2 vCPU / 4GB cobre k3s + 3 APIs + 2 Redis com folga."
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Usuário sem privilégio. O Ansible e o CI usam sudo; ninguém entra como root."
  type        = string
  default     = "zispuser"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/zisp.pub"
}

# A VNet não pode encostar na faixa da VPN, senão o roteamento quebra de um
# jeito muito difícil de diagnosticar. O role `common` aborta se o IP privado
# da VM cair dentro de 10.19.24.0/22.
variable "vnet_address_space" {
  type    = list(string)
  default = ["172.16.0.0/16"]
}

variable "subnet_address_prefix" {
  type    = list(string)
  default = ["172.16.1.0/24"]
}

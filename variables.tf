variable "tenancy_ocid" {
  description = "OCID da tenancy OCI"
  type        = string
}

variable "user_ocid" {
  description = "OCID do usuário usado para autenticação da API"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint da chave pública da API cadastrada no console OCI"
  type        = string
}

variable "private_key_path" {
  description = "Caminho local para a chave privada da API (não usado no GitHub Actions, que usará private_key diretamente)"
  type        = string
  default     = null
}

variable "private_key" {
  description = "Conteúdo da chave privada da API (usado no GitHub Actions via secret, alternativa a private_key_path)"
  type        = string
  default     = null
  sensitive   = true
}

variable "region" {
  description = "Região OCI onde os recursos serão provisionados"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID do compartment onde os recursos do projeto serão criados (opentofu-lab)"
  type        = string
}

variable "bastion_allowed_cidr" {
  description = "Lista de CIDRs autorizados a abrir sessões no Bastion (ex: seu IP público /32)"
  type        = list(string)
}

variable "instance_ssh_public_key" {
  description = "Chave pública SSH injetada na instância (distinta da chave da API e da chave do Bastion)"
  type        = string
}
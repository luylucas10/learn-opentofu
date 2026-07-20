output "bastion_id" {
  description = "OCID do Bastion Service, usado para abrir sessões de conexão"
  value       = oci_bastion_bastion.main.id
}

output "instance_private_ips" {
  description = "IPs privados das instâncias, indexados na mesma ordem do count (usados como target das sessões do Bastion)"
  value       = oci_core_instance.main[*].private_ip
}

output "instance_names" {
  description = "Nomes das instâncias criadas"
  value       = oci_core_instance.main[*].display_name
}

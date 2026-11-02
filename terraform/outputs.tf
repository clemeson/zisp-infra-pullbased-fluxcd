# ESTE output e o unico contrato com o resto do repositorio: o
# ansible/inventory.sh le `public_ip` e monta o inventario. Qualquer stack de
# outro provedor que exponha o mesmo nome encaixa sem mudar mais nada.
output "public_ip" {
  value = azurerm_public_ip.main.ip_address
}

output "ssh" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
}

output "dns_records" {
  description = "Registros A que precisam apontar para este IP."
  value = {
    for h in ["vpn.zisp.com.br", "api.zisp.com.br", "super-api.zisp.com.br"] :
    h => azurerm_public_ip.main.ip_address
  }
}

locals {
  tags = {
    Project   = "zisp"
    ManagedBy = "terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.vm_name}-vnet"
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "main" {
  name                 = "${var.vm_name}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.subnet_address_prefix
}

# Static, nao Dynamic: os registros A (api.zisp, super-api.zisp, vpn.zisp)
# apontam para ele, e o HTTP-01 do cert-manager exige registro A -- nao aceita
# CNAME. Um IP Dynamic muda num stop/start e derruba tudo ate o DNS propagar.
#
# Mesmo assim, o Mikrotik aponta para o DOMINIO e nao para este IP. O IP
# estatico evita a troca acidental; o dominio permite a troca deliberada,
# inclusive de provedor.
resource "azurerm_public_ip" "main" {
  name                = "${var.vm_name}-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "main" {
  name                = "${var.vm_name}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Firewall
#
# Regras inline (security_rule), nao recursos separados: assim o Terraform e
# AUTORITATIVO -- regra criada a mao no portal e nao listada aqui some no
# proximo apply. E o que se quer depois de um incidente de drift.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "main" {
  name                = "${var.vm_name}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-ssh"
    description                = "SSH: Ansible e o workflow de bootstrap."
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http"
    description                = "Traefik + desafio HTTP-01 do cert-manager. Sem ela o certificado nao renova."
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    description                = "Traefik: api.zisp.com.br e super-api.zisp.com.br."
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # L2TP puro, sem IPsec: so 1701/udp. Se um dia voltar o IPsec, precisa
  # tambem 500/udp, 4500/udp e os protocolos ESP/AH.
  security_rule {
    name                       = "allow-l2tp"
    description                = "L2TP sem IPsec - tunel dos Mikrotik (rede 10.19.24.0/22)."
    priority                   = 1030
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "1701"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # A 6443 NAO e aberta. O kubectl do CI roda dentro da VPS por SSH.

  tags = local.tags
}

# A associacao e recurso separado na Azure, e precisa ser declarada: um NSG que
# existe mas nao esta associado a nada nao filtra pacote nenhum, e nao da erro
# em lugar algum -- falha silenciosa que parece firewall funcionando.
resource "azurerm_network_interface_security_group_association" "main" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_linux_virtual_machine" "main" {
  name                  = var.vm_name
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.main.id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  # Ubuntu 24.04. O role `common` aborta em qualquer outra distro: os caminhos
  # do ppp e o pacote linux-modules-extra sao especificos de Debian/Ubuntu.
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = local.tags
}

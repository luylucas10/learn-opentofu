terraform {
  required_providers {
    oci = {
      source  = "opentofu/oci"
      version = "8.23.0"
    }
  }
}

# Autenticação via variáveis explícitas (não via ~/.oci/config), para funcionar
# tanto localmente (terraform.tfvars) quanto no GitHub Actions (TF_VAR_* / secrets).
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Rede virtual isolada do projeto. CIDR /16 cobre toda a faixa de IPs internos
# que poderá ser subdividida em subnets.
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "opentofu-lab-vcn"
  dns_label      = "opentofulab"
}

# Subnet privada onde a VM vai residir. prohibit_public_ip_on_vnic = true garante
# que nenhuma instância aqui pode receber IP público, mesmo por engano.
# Acesso SSH só acontece via túnel do Bastion Service, nunca diretamente.
resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "opentofu-lab-private-subnet"
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
}

# Permite tráfego de saída (updates, pacotes) a partir da subnet privada,
# sem expor nenhuma instância a conexões de entrada vindas da internet.
resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "opentofu-lab-nat-gw"
}

# Referência dinâmica aos serviços OCI (Object Storage, etc.), usada pelo
# Service Gateway. Evita hardcode do OCID do serviço, que varia por região.
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# Permite que a subnet privada acesse serviços OCI (Object Storage, Bastion, etc.)
# pela rede interna da Oracle, sem sair para a internet pública.
resource "oci_core_service_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "opentofu-lab-sgw"

  services {
    service_id = data.oci_core_services.all_oci_services.services[0].id
  }
}

# Tabela de rotas da subnet privada: tráfego geral sai pelo NAT Gateway;
# tráfego destinado a serviços OCI sai pelo Service Gateway.
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "opentofu-lab-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_nat_gateway.main.id
  }

  route_rules {
    destination       = data.oci_core_services.all_oci_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.main.id
  }
}

# Firewall da subnet privada. Egress liberado (necessário para updates via NAT).
# Ingress restrito à própria VCN (10.0.0.0/16): SSH nunca é aberto para a
# internet — só chega via túnel criado pelo Bastion Service, de dentro da VCN.
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "opentofu-lab-private-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH (porta 22), somente a partir de dentro da própria VCN.
  ingress_security_rules {
    source   = "10.0.0.0/16"
    protocol = "6" # TCP
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP tipo 3 código 4 (Destination Unreachable: Fragmentation Needed),
  # necessário para Path MTU Discovery. Regra mínima de ICMP recomendada
  # pela Oracle mesmo em subnets fechadas.
  ingress_security_rules {
    source   = "10.0.0.0/16"
    protocol = "1" # ICMP
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# Bastion Service: ponto de entrada gerenciado pela Oracle para sessões SSH
# temporárias até a subnet privada. Não expõe porta alguma da VM à internet.
resource "oci_bastion_bastion" "main" {
  compartment_id               = var.compartment_ocid
  bastion_type                 = "STANDARD"
  target_subnet_id             = oci_core_subnet.private.id
  name                         = "opentofu-lab-bastion"
  client_cidr_block_allow_list = var.bastion_allowed_cidr
  max_session_ttl_in_seconds   = 10800 # 3 horas, máximo permitido pelo serviço
}

# Availability Domain: pega o primeiro disponível na região configurada.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Imagem mais recente do Oracle Linux compatível com o shape AMD (E2.1.Micro).
data "oci_core_images" "oracle_linux" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Duas instâncias VM.Standard.E2.1.Micro (shape fixo, sem shape_config),
# cobrindo o limite Always Free de 2 instâncias AMD.
resource "oci_core_instance" "main" {
  count               = 2
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "opentofu-lab-vm-${count.index}"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.instance.id]
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.oracle_linux.images[0].id
  }

  metadata = {
    ssh_authorized_keys = var.instance_ssh_public_key
    user_data           = base64encode(file("${path.module}/cloud-init.yaml"))
  }
}

resource "oci_core_network_security_group" "instance" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "opentofu-lab-instance-nsg"
}

resource "oci_core_network_security_group_security_rule" "instance_ssh_ingress" {
  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "10.0.0.0/16"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "instance_egress_all" {
  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}
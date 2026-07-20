# learn-opentofu — VM Always Free na Oracle Cloud via OpenTofu

Provisiona uma infraestrutura de VM na Oracle Cloud Infrastructure (OCI), tier **Always Free**, usando **OpenTofu**. A VM fica em subnet privada (sem IP público), acessível apenas via **Bastion Service**.

Escopo deste projeto: provisionamento local via OpenTofu + acesso seguro via Bastion. Remote state (Object Storage S3-compatible) e GitHub Actions ficam fora do escopo por ora — o provider já está preparado para isso (autenticação via variáveis explícitas), caso o projeto seja retomado no futuro.

## Visão geral

- **OpenTofu**: alternativa open source do Terraform, usada para provisionar recursos de forma declarativa em vez de manualmente pela CLI/console.
- **OCI**: nuvem onde os recursos são provisionados.
- **OCI CLI**: usada para inspeção manual dos recursos e para gerar as credenciais de API iniciais.

## Arquitetura

```
VCN (10.0.0.0/16)
 ├─ Subnet privada (10.0.1.0/24) — regional
 │    └─ 2x VM.Standard.E2.1.Micro (sem IP público)
 ├─ NAT Gateway — saída de internet para as VMs
 ├─ Service Gateway — acesso a serviços OCI sem internet pública
 ├─ Route Table (privada) — 0.0.0.0/0 → NAT GW; CIDR de serviços OCI → Service GW
 ├─ Security List — ingress restrito a 10.0.0.0/16 (SSH + ICMP), egress liberado
 └─ NSG (por instância) — mesma política da Security List, camada redundante

Bastion Service (gerenciado pela Oracle)
 └─ sessões SSH efêmeras (TTL até 3h) sob demanda até a subnet privada
```

Nenhuma porta é exposta à internet: o acesso SSH acontece por um túnel criado sob demanda pelo Bastion Service, de dentro da própria VCN.

## Conceitos-chave da OCI

### Compartment

- Agrupador lógico/administrativo de recursos dentro da tenancy — não é um recurso computacional nem de rede.
- Serve para organizar recursos relacionados, controlar acesso via IAM Policies e facilitar limpeza/visualização de custo.
- Não tem delete imediato: fica em `lifecycle-state: DELETING → DELETED` somente depois de vazio.
- Este projeto usa o compartment `opentofu-lab`, dentro do qual todos os recursos (VCN, subnet, instâncias, etc.) são criados.

### Always Free eligible resources (relevantes para uma VM)

- **Compute**: 2x VM.Standard.E2.1.Micro (AMD) OU até 4 OCPUs / 24GB RAM em Ampere A1 (ARM), divisíveis entre até 4 VMs. O teto de E2.1.Micro é fixo em 2 instâncias por tenancy; A1.Flex é um pool de OCPU/RAM divisível, mais vantajoso em poder computacional, mas com disponibilidade sujeita a "Out of Capacity" por região.
- **Block Volume**: até 200GB total grátis (boot volume sai desse mesmo pool).
- **VCN**: até 2 VCNs grátis por tenancy.

### Rede (VCN e Subnet)

- **VCN**: rede virtual isolada, definida por um CIDR (ex: `10.0.0.0/16`). O provider OCI aceita de `/16` até `/30` tanto em VCN quanto em subnet — os tamanhos usados aqui são por convenção/margem de crescimento, não exigência técnica.
- **Subnet**: subdivisão do CIDR da VCN. Pode ser **regional** (recomendado, funciona em qualquer Availability Domain) e **pública ou privada**. Subnet privada + Bastion Service é a escolha deste projeto para máxima segurança.
- **Internet Gateway**: necessário só para subnet pública (não usado aqui).
- **NAT Gateway**: permite saída de internet a partir da subnet privada, sem permitir entrada.
- **Service Gateway**: acesso a serviços OCI (Object Storage, etc.) sem passar pela internet pública.
- **Route Table**: define para onde vai o tráfego de saída de cada subnet.
- **Security List** (nível de subnet) / **NSG** (nível de instância, mais granular): definem regras de ingress/egress. Este projeto usa os dois, como defesa em profundidade.

### Bastion Service

Serviço gerenciado pela Oracle, gratuito, para acesso SSH temporário a subnets privadas sem expor IP público nem porta 22.

- Um recurso **Bastion** é associado à VCN/subnet, com um **CIDR allowlist** de quem pode abrir sessões.
- **Port Forwarding Session** (usada aqui): cria um túnel genérico até uma porta específica de um host privado.
- **Managed SSH Session**: alternativa que depende do agente do Bastion rodando na instância (Oracle Cloud Agent).
- Sessões são efêmeras, com TTL configurável (máximo e padrão de 3h neste projeto).
- Fluxo: sessão do Bastion cria um túnel SSH local → dentro do túnel, SSH normal até a instância usando a chave da própria VM (diferente da chave usada para autenticar no Bastion).

### Compute Instance

- **Shape**: define CPU/RAM/arquitetura. Este projeto usa `VM.Standard.E2.1.Micro` (AMD, x86, shape fixo — 1 OCPU/1GB, sem `shape_config`), após uma tentativa com `VM.Standard.A1.Flex` (ARM) falhar por falta de capacidade na região (`500 InternalError: Out of host capacity` — problema de disponibilidade, não de configuração).
- **Imagem**: obtida via data source `oci_core_images`, filtrando por SO, versão e shape, evitando OCID hardcoded. Usa Oracle Linux 9, compatível com x86.
- **Boot Volume**: criado automaticamente a partir da imagem, dentro do pool de 200GB grátis, criptografado por padrão.
- **Autenticação inicial**: chave SSH pública própria da instância (`ssh_authorized_keys`), injetada via cloud-init no primeiro boot no usuário `opc`. Não há login por senha nem root direto. É uma chave distinta da chave da API (OpenTofu/CLI) e da chave usada no Bastion.
- **Cloud-init / user_data**: script `#cloud-config` rodado no primeiro boot para hardening automático — atualização de pacotes, reforço de `PasswordAuthentication no` / `PermitRootLogin no`, ativação do firewalld.
- **Availability Domain**: obtido via data source `oci_identity_availability_domains`, pegando o primeiro disponível na região.

### Segurança da instância

- Bastion Service elimina exposição da porta 22.
- Cloud-init aplica hardening automático no primeiro boot.
- Block Volumes criptografados em repouso por padrão.
- Nenhuma senha ou acesso root habilitado — autenticação somente por chave.

## OpenTofu — pontos específicos para OCI

- **Provider**: `opentofu/oci`.
- **Autenticação**: variáveis explícitas (`tenancy_ocid`, `user_ocid`, `fingerprint`, `private_key_path`/`private_key`, `region`) em vez de `~/.oci/config` — mantido assim mesmo fora do escopo do GitHub Actions atual, por já deixar o provider desacoplado de config local.
- **Data sources úteis**: `oci_identity_availability_domains`, `oci_core_images`, `oci_core_services`.
- **State**: local (`terraform.tfstate`), git-ignored. Fora do escopo atual: remote state (Object Storage S3-compatible) e GitHub Actions — ficam documentados como possível extensão futura, não pendência do projeto.
- **`required_version`**: fixado em `terraform { required_version = ">= 1.12.0" }` — trava a versão mínima do próprio OpenTofu (separado da versão do provider), evitando incompatibilidades ao rodar em outra máquina.
- **`outputs.tf`**: expõe `bastion_id`, `instance_private_ips` e `instance_names`, eliminando a necessidade de `tofu state show` manual para conectar via Bastion (usado por `scripts/03.conectar-instancia.ps1`).

### Nota sobre `source_details` no `oci_core_instance`

No provider `oracle/oci` (v8.23.0), o argumento correto para o OCID da imagem dentro de `source_details` é **`source_id`**, não `image_id` — erro comum que gera "Unsupported argument" no `tofu plan`.

## OCI CLI

Usada para inspeção manual (`oci compute instance list`, `oci network vcn list`, etc.) e para gerar a API key inicial.

### Setup

```bash
oci setup config
```

Fluxo: informar user OCID e tenancy OCID (obtidos em Profile → My Profile no console), escolher a region, gerar um novo par de chaves RSA (a privada nunca sai da máquina). Ao final, a chave pública (`oci_api_key_public.pem`) precisa ser cadastrada manualmente no console: Profile → My Profile → API Keys → Add API Key → Paste Public Key.

Testar com:

```bash
oci iam region list
```

## Estrutura do projeto

```
main.tf              # provider, rede, bastion, compute
variables.tf          # variáveis de autenticação e configuração
outputs.tf             # bastion_id, IPs privados e nomes das instâncias
terraform.tfvars      # valores reais (local, git-ignored)
cloud-init.yaml       # hardening da instância no primeiro boot
scripts/
  01.oci-login.ps1            # configuração inicial do OCI CLI
  02.criar-compartment.ps1    # criação do compartment do projeto
  03.conectar-instancia.ps1   # cria sessão no Bastion e conecta via SSH
```

## Como conectar em uma instância

Sessões do Bastion são efêmeras (TTL até 3h), então não há necessidade de guardar sessão — o script cria uma nova a cada execução. O `bastion_id` e os IPs privados vêm de `outputs.tf`, sem precisar consultar o state manualmente.

```powershell
./scripts/03.conectar-instancia.ps1               # conecta na instância [0]
./scripts/03.conectar-instancia.ps1 -InstanceIndex 1
```

## Estado atual — escopo concluído

- OCI CLI configurado e testado.
- Compartment `opentofu-lab` criado.
- Rede (VCN, subnet privada, NAT Gateway, Service Gateway, Route Table, Security List), NSG e Bastion Service implementados e aplicados.
- 2x `VM.Standard.E2.1.Micro` provisionadas na subnet privada; conexão via Bastion testada com sucesso.

Fora do escopo (possível extensão futura, não implementado): remote state em Object Storage S3-compatible e workflow do GitHub Actions.

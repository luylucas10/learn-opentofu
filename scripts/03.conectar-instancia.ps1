# Conecta a uma instância na subnet privada via túnel do Bastion Service.
# Sessões do Bastion são efêmeras (TTL máx. 3h) — este script cria uma nova
# sessão a cada execução, então não precisa reaproveitar sessão antiga.

$bastionId   = "<bastion-ocid>"        # tofu state show oci_bastion_bastion.main
$targetIp    = "<instance-private-ip>" # tofu state show 'oci_core_instance.main[0]' (ou [1])
$sshKeyPath  = "$HOME/.ssh/opentofu-lab"
$localPort   = 2222

# 1. Cria a sessão de port forwarding no Bastion
$session = oci bastion session create-port-forwarding `
  --bastion-id $bastionId `
  --target-private-ip $targetIp `
  --target-port 22 `
  --session-ttl 10800 `
  --ssh-public-key-file "$sshKeyPath.pub" `
  --display-name "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
  --wait-for-state SUCCEEDED --wait-for-state FAILED `
  | ConvertFrom-Json

$sessionId = $session.data.resources[0].identifier
$region    = "sa-saopaulo-1"

Write-Host "Sessão criada: $sessionId"

# 2. Abre o túnel SSH em uma nova janela (fica aberto até você fechar)
Start-Process pwsh -ArgumentList @(
  "-NoExit", "-Command",
  "ssh -i `"$sshKeyPath`" -N -L ${localPort}:${targetIp}:22 -p 22 ${sessionId}@host.bastion.${region}.oci.oraclecloud.com"
)

Write-Host "Túnel abrindo em nova janela (localhost:$localPort -> $targetIp:22)..."
Start-Sleep -Seconds 5

# 3. Conecta via SSH através do túnel
ssh -i "$sshKeyPath" -p $localPort opc@localhost

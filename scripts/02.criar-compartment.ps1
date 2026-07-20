# gerar um compartment, que é um container lógico para recursos da OCI.

oci iam compartment create `
  --compartment-id <tenancy-id> `
  --name "opentofu-lab" `
  --description "Recursos provisionados via OpenTofu para testes" `
  --wait-for-state ACTIVE

# salvar json de saída em arquivo

oci iam compartment list --compartment-id <tenancy-id> --all
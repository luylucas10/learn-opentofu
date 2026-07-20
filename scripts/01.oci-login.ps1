# instalar oci,
# obter os seguintes dados do console da OCI:
# user ocid: profile > aba Details
# tenant ocid: tenancy > aba Details
# region: a region que escolheu
# vai perguntar caminhos para salver arquivos, siga com o padrão e não 
# adicione senha para a chave privada, coloque N/A
oci setup config 

# no fim, vai criar um par de chaves.

cat ~/.oci/oci_api_key_public.pem

# no console, vai em profile > Tokens and Keys > API Keys > Add Public Key, e cole a chave pública que foi gerada.
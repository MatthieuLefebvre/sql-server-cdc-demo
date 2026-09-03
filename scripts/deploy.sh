#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID.}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP.}"
LOCATION="${AZURE_LOCATION:?Set AZURE_LOCATION to the Fabric capacity region.}"
STACK_NAME="${AZURE_STACK_NAME:-fabric-rti-phase1}"
TEMPLATE_FILE="${TEMPLATE_FILE:-infra/main.bicep}"
PARAMETERS_FILE="${PARAMETERS_FILE:-infra/main.bicepparam}"

if [[ "$LOCATION" == *"FILL ME"* ]]; then
  echo "AZURE_LOCATION must be the real Fabric capacity region." >&2
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"
az group show --name "$RESOURCE_GROUP" --output none

for provider in Microsoft.Compute Microsoft.Network Microsoft.KeyVault Microsoft.SqlVirtualMachine Microsoft.DevTestLab Microsoft.MessagingConnectors; do
  az provider register --namespace "$provider" --wait
done

if [[ -z "${VM_ADMIN_PASSWORD:-}" ]]; then
  VM_ADMIN_PASSWORD="$(openssl rand -base64 48 | tr -d '\r\n')Aa1!"
  GENERATED_PASSWORD=true
else
  GENERATED_PASSWORD=false
fi
export VM_ADMIN_PASSWORD

az bicep build --file "$TEMPLATE_FILE" --stdout >/dev/null

az stack group create \
  --name "$STACK_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  --parameters "$PARAMETERS_FILE" location="$LOCATION" \
  --action-on-unmanage deleteAll \
  --deny-settings-mode none \
  --yes

KEY_VAULT_NAME="$(az stack group show --name "$STACK_NAME" --resource-group "$RESOURCE_GROUP" --query "outputs.keyVaultName.value" --output tsv)"
unset VM_ADMIN_PASSWORD

echo "Phase 1 deployment completed."
echo "Key Vault: $KEY_VAULT_NAME"
echo "Credential secret: sql-bootstrap-password"
if [[ "$GENERATED_PASSWORD" == true ]]; then
  echo "A credential was generated and stored in Key Vault. It was not written to a local file."
fi

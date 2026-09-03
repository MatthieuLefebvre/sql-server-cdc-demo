#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID.}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP.}"
STACK_NAME="${AZURE_STACK_NAME:-fabric-rti-phase1}"

az account set --subscription "$SUBSCRIPTION_ID"

KEY_VAULT_NAME="$(az stack group show --name "$STACK_NAME" --resource-group "$RESOURCE_GROUP" --query "outputs.keyVaultName.value" --output tsv 2>/dev/null || true)"

az stack group delete \
  --name "$STACK_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --action-on-unmanage deleteAll \
  --yes

if [[ -n "$KEY_VAULT_NAME" ]]; then
  az keyvault purge --name "$KEY_VAULT_NAME" --no-wait 2>/dev/null || true
fi

echo "Phase 1 deployment stack and its managed resources were removed."

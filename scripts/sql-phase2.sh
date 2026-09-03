#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID.}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP.}"
STACK_NAME="${AZURE_STACK_NAME:-fabric-rti-phase1}"
NORTH_VM_NAME="${NORTH_VM_NAME:-sql-demo-north}"
SOUTH_VM_NAME="${SOUTH_VM_NAME:-sql-demo-south}"
SQL_ADMIN_USERNAME="${SQL_ADMIN_USERNAME:-fabriccdc}"
CONNECTOR_SUBNET="${CONNECTOR_SUBNET:-10.42.2.0/27}"

ACTION="${1:-}"
TARGET="${2:-all}"

case "$ACTION" in
  bootstrap) SQL_FILE="sql/bootstrap.sql"; MODE="Bootstrap" ;;
  change) SQL_FILE="sql/generate-change.sql"; MODE="Execute" ;;
  reset) SQL_FILE="sql/reset-data.sql"; MODE="Execute" ;;
  diagnostics) SQL_FILE="sql/diagnostics.sql"; MODE="Execute" ;;
  *)
    echo "Usage: $0 {bootstrap|change|reset|diagnostics} [all|north|south]" >&2
    exit 2
    ;;
esac

case "$TARGET" in
  all|north|south) ;;
  *)
    echo "Target must be all, north, or south." >&2
    exit 2
    ;;
esac

for required_file in scripts/configure-sql-vm.ps1 "$SQL_FILE"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Run this script from the repository root; missing $required_file." >&2
    exit 1
  fi
done

az account set --subscription "$SUBSCRIPTION_ID"
az group show --name "$RESOURCE_GROUP" --output none

KEY_VAULT_NAME="$(az stack group show \
  --name "$STACK_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'outputs.keyVaultName.value' \
  --output tsv)"

if [[ -z "$KEY_VAULT_NAME" ]]; then
  echo "The deployment stack did not return a Key Vault name." >&2
  exit 1
fi

SQL_SCRIPT_BASE64="$(gzip -c "$SQL_FILE" | base64 | tr -d '\r\n')"

run_for_vm() {
  local vm_name="$1"
  local tenant_id="$2"
  local source_instance="$3"

  echo "Running $ACTION on $vm_name ($tenant_id)..."
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$vm_name" \
    --command-id RunPowerShellScript \
    --scripts @scripts/configure-sql-vm.ps1 \
    --parameters \
      "TenantId=$tenant_id" \
      "SourceInstance=$source_instance" \
      "KeyVaultName=$KEY_VAULT_NAME" \
      "SqlScriptBase64=$SQL_SCRIPT_BASE64" \
      "Mode=$MODE" \
      "Compression=Gzip" \
      "SqlAdminUsername=$SQL_ADMIN_USERNAME" \
      "ConnectorSubnet=$CONNECTOR_SUBNET" \
    --query 'value[].message' \
    --output tsv
}

if [[ "$TARGET" == "all" || "$TARGET" == "north" ]]; then
  run_for_vm "$NORTH_VM_NAME" 'CONTOSO_NORTH' 'NORTH'
fi

if [[ "$TARGET" == "all" || "$TARGET" == "south" ]]; then
  run_for_vm "$SOUTH_VM_NAME" 'CONTOSO_SOUTH' 'SOUTH'
fi
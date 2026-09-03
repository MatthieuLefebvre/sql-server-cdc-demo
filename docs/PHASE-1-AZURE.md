# Phase 1 - Azure infrastructure

## Review status

The reference environment was deployed and validated in the same region as its Fabric capacity. The workspace identity received the required VNet role, and Phase 3 proved private SQL connectivity through a Streaming VNet data gateway bound to `streaming-connectors`.

## Deployed topology

- One VNet with a private SQL subnet and no public IP addresses.
- One dedicated `/27` subnet delegated to `Microsoft.MessagingConnectors/connectors`.
- Two independent SQL Server 2022 Developer VMs with static private endpoints on TCP 1433.
- SQL IaaS Agent registration with private connectivity and a Basic SQL login for the Fabric CDC connector.
- One Premium SSD data disk per VM, managed boot diagnostics, Trusted Launch, and system-assigned identity.
- Daily DevTestLab auto-shutdown schedules, enabled by default at 19:00 UTC.
- One RBAC-enabled Key Vault containing the runtime-generated bootstrap credential.
- Optional Network Contributor assignment for the Fabric workspace identity at VNet scope.

The database named `VistaERP`, Windows firewall configuration, CDC, Change Tracking, and demo data belong to Phase 2. The Streaming VNet data gateway and Eventstreams belong to Phase 3.

## Required inputs

1. Confirm the workspace remains assigned to capacity in the deployment region before Phase 3.
2. Confirm `Standard_D4as_v6` and the SQL 2022 Developer image remain available in that region.
3. Confirm the workspace identity remains active and the deployer can create role assignments.
4. Update the short-lived `expiresOn` tag when extending the demo lifetime.
5. Confirm the `10.42.0.0/16` plan does not overlap connected networks. It avoids Fabric-reserved `10.240.0.0/16` and `10.224.0.0/12`.

## Deploy and remove

From Bash, WSL, Git Bash, or Azure Cloud Shell:

```bash
export AZURE_LOCATION="westcentralus"
./scripts/deploy.sh
```

Set `VM_ADMIN_PASSWORD` before deployment to supply a controlled credential. If omitted, the script generates a high-entropy value in memory and the deployment stores it as the `sql-bootstrap-password` Key Vault secret. No secret belongs in `main.bicepparam`, shell history, or source control.

The deployment uses an Azure deployment stack. Re-running it is idempotent; resources removed from the template are deleted because `action-on-unmanage` is `deleteAll`.

```bash
./scripts/teardown.sh
```

Teardown deletes only resources managed by the stack, not the pre-existing resource group. It then requests purge of the soft-deleted demo vault so its deterministic name can be reused. Purge can be blocked by subscription policy or insufficient permission; in that case, an authorized operator must purge or recover the vault.

## One-day cost estimate

The estimate is directional. Two `Standard_D4as_v6` Windows VMs in West Central US dominate cost. SQL Server Developer edition adds no production SQL license charge and is licensed only for nonproduction use.

| Item | Quantity | Approximate running cost |
|---|---:|---:|
| Windows `Standard_D4as_v6` | 2 | Verify current subscription pricing before extending the demo |
| Premium SSD OS and 128-GiB data disks | 4 | about $0.10-$0.14/hour total |
| Key Vault, NICs, VNet, schedules | 1 set | under $0.10/day at demo volume |
| Estimated 8-hour demo day | | **about $7-$9** |
| Accidental 24-hour run | | **about $21-$26** |

Storage continues billing while VMs are deallocated. Data transfer, backup, Defender, Fabric capacity, and taxes are excluded. Recalculate with Azure Pricing Calculator after the real region and negotiated agreement are known.

## Phase 1 acceptance checks

- `az bicep build --file infra/main.bicep` succeeds.
- An Azure validation or what-if succeeds in the Fabric-aligned region.
- Both NICs have no public IP and retain their expected static addresses.
- SQL NSG allows TCP 1433 only from the connector subnet; broader VNet inbound is denied.
- The connector subnet is dedicated, empty before gateway creation, `/27` or larger, and delegated correctly.
- The workspace identity has Network Contributor on the VNet.
- Both SQL VM and auto-shutdown resources report `Succeeded`.
- The bootstrap secret exists in Key Vault and no repository file contains its value.
- Deploy twice, then run teardown and confirm the stack has no managed resources left.

Private endpoint reachability through the actual Streaming VNet data gateway cannot be proven until the gateway is created in Phase 3. Phase 1 proves and exposes the required connector-network topology; final end-to-end reachability remains a Phase 3 gate.

## Phase 1 review stop

Review the Bicep, security posture, region, cost assumptions, and teardown behavior before Phase 2. No database, CDC, Change Tracking, Eventstream, Eventhouse, KQL, or OneLake implementation is included here.
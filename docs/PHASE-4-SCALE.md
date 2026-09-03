# Phase 4 - Manifest-driven scale

## Status

The two-instance Fabric deployment is represented by `config/instances.json`. Both `Plan` and `Apply` were run against the live workspace on 2026-08-26. Each found the gateway, two SQL connections, two Eventstreams, and KQL Queryset by name with zero creates. The post-apply acceptance validator reported zero failures across source identity, landing, and OneLake mirroring.

This proves repeatable reconciliation for the deployed topology. Phase 5 subsequently proved isolated empty-to-live workspace provisioning, Fabric long-running-operation completion, runtime activation, strict acceptance, and complete cleanup.

## Manifest contract

Each entry in `instances` owns one SQL source and one deterministic business identity mapping:

| Field | Contract |
|---|---|
| `name` | Unique lower-case resource key using letters, digits, and hyphens |
| `tenantId` | Unique governed business tenant identifier |
| `sourceInstance` | Unique stable SQL instance identifier |
| `server`, `database` | Private SQL endpoint and source database |
| `connectionName` | Unique Fabric SQL connection name |
| `eventstreamName` | Unique Fabric Eventstream name |
| `landingTable` | Unique KQL table name |

The manifest also fixes the workspace and folder, Streaming VNet gateway binding, Eventhouse database, Queryset, and CDC source-table allowlist. Live resource IDs are recorded for validation, while provisioning discovers existing resources by their unique display names.

The generated Eventstream always places a streaming SQL operator between the source and destination. It appends that instance's fixed `tenant_id` and `source_instance`; the Eventhouse destination consumes only the derived stream. Do not replace this with connector metadata or post-landing enrichment.

## Commands

Sign in with Azure CLI, then preview changes:

```powershell
az login
.\scripts\apply-phase4.ps1 -Mode Plan
```

Apply the manifest and reassert the five-minute OneLake mirroring policy:

```powershell
.\scripts\apply-phase4.ps1 -Mode Apply
.\scripts\validate-phase3.ps1
```

When all named resources exist, no SQL credential is required. To create a missing connection, obtain the credential through the approved secret workflow and pass it only in memory:

```powershell
$sqlCredential = Get-Credential -UserName fabriccdc
.\scripts\apply-phase4.ps1 -Mode Apply -SqlCredential $sqlCredential
$sqlCredential = $null
```

The script never writes the password to the manifest or output. Connection creation uses mandatory connection testing and fails when no credential is supplied. Do not place a password on the command line or in a file.

## Adding an instance

1. Provision the private SQL Server and configure the same CDC table set.
2. Add one unique `instances` entry with its governed tenant and source mapping.
3. Run `Plan` and review every proposed create.
4. Run `Apply` with an in-memory credential if the SQL connection is new.
5. Wait for the Eventstream source and destination to become active.
6. Run the validator and accept the instance only when all identity and mirroring checks return zero failures.

Treat an existing display name as ownership of that resource. `Apply` does not overwrite an existing definition. The validator exports and checks the live graph, connection binding, injected constants, landed mappings, and mirroring state so configuration drift fails visibly.

## Validated result

The live no-op run reported:

```text
instances: 2
resources present: 6
resources to create: 0
post-apply validation failures: 0
landed identity checks: 2
mirrored tables: 2
```

## Boundaries

- Fresh Eventstream and Queryset creation can return HTTP 202 long-running operations. The script polls `x-ms-operation-id` using `Retry-After`, fails on terminal operation errors, and retrieves the operation result for created item IDs.
- DeltaFlow automatic table management remains incompatible with the required pre-landing identity operator in the validated public-definition topology. Fixed landing tables are intentional.
- SQL Server VM CDC currently requires Basic credentials and the connector's documented unencrypted-connection setting. Direct Key Vault references and automated credential rotation are not implemented.
- The unused `fabric-rti-streaming-vnet` discovery gateway remains because the documented delete endpoint returns `UnknownError`. No connection uses it; do not alter the valid corrected gateway while cleaning it up.
- `manage-disposable-fabric.ps1` owns isolated workspace, identity, Eventhouse, KQL database, generated manifest, and teardown for rehearsal. Production Eventhouse lifecycle remains separate from `apply-phase4.ps1`.
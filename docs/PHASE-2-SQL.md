# Phase 2 - SQL Server sources

## Scope and status

Phase 2 provides the repeatable guest configuration and SQL assets for two independent SQL Server 2022 VMs. It does not create Fabric connections, Eventstreams, Eventhouse, KQL, or OneLake items.

The assets are deployed and live-validated on both Azure VMs. Both `VistaERP` databases have matching DDL, six CDC and Change Tracking tables, healthy capture/cleanup jobs, distinct source markers, and deterministic heartbeat changes. Phase 3 also proved that the `fabriccdc` login can snapshot both databases over the private Streaming VNet gateway.

## Source contract

Both servers host a database named `VistaERP` and execute the same `sql/bootstrap.sql` file. The schema contains:

| Table | Demo role | Overlapping seed key |
|---|---|---:|
| `dbo.Projects` | Project master | `1001` |
| `dbo.JobCosts` | Posted costs | `9001` |
| `dbo.WorkOrders` | Maintenance work | `7001` |
| `dbo.Equipment` | Equipment master | `501` |
| `dbo.Invoices` | Billing | `8001` |
| `dbo.DemoHeartbeat` | Synthetic liveness signal | `1` |

Every table has a primary key and is enabled for both CDC and Change Tracking. Change Tracking is comparison-only; it is not represented as a Fabric Eventstream source.

Source tables intentionally do not contain `tenant_id` or `source_instance`. Distinct `CONTOSO_NORTH` and `CONTOSO_SOUTH` business markers prove that the rows came from different databases, but they are not accepted as the downstream tenancy mechanism. Phase 3 must inject governed identity during streaming before landing.

## Security and host configuration

The SQL IaaS Agent creates the `fabriccdc` SQL login from the Phase 1 runtime credential. Each VM system-assigned identity receives the `Key Vault Secrets User` role on the demo vault. During a Run Command operation, the in-guest script:

1. Uses the Instance Metadata Service to obtain a managed identity token.
2. Reads `sql-bootstrap-password` directly from Key Vault into memory.
3. Configures the data disk, SQL TCP port `1433`, the connector-subnet Windows Firewall rule, and SQL Agent.
4. Executes SQL through an in-memory .NET connection.

The credential is never passed as a Run Command parameter, returned in command output, or written to a repository file. The subnet NSG remains the authoritative restriction allowing SQL ingress only from `10.42.2.0/27`.

## Operations

Run commands from the repository root after Phase 1 deployment. Role assignment propagation can take several minutes after a new deployment.

```bash
# Configure both hosts and create/seed/track both VistaERP databases.
./scripts/sql-phase2.sh bootstrap all

# Generate one deterministic transaction on each source.
./scripts/sql-phase2.sh change all

# Return mutable demo rows to the baseline while producing CDC events.
./scripts/sql-phase2.sh reset all

# Print CDC, Change Tracking, heartbeat, memory, and transaction-log health.
./scripts/sql-phase2.sh diagnostics all
```

The optional second argument is `all`, `north`, or `south`. Environment overrides follow the Phase 1 scripts: `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, and `AZURE_STACK_NAME`; VM names, SQL login, and connector CIDR can also be overridden.

Azure Action Run Command returns only the last 4,096 bytes of output. The diagnostics place the most operationally useful heartbeat and host-overhead rows near the end, but sustained monitoring must use a proper telemetry destination in a later production design.

## Live acceptance gate

Phase 2 is complete only when the deployed environment proves all of the following:

- Both `@@SERVERNAME` values differ while `DB_NAME()` returns `VistaERP` on each.
- All six table names, columns, keys, and tracking settings match on both instances.
- Project `1001` exists on both and its visible marker is `CONTOSO_NORTH` or `CONTOSO_SOUTH` as appropriate.
- SQL Agent is running; CDC capture and cleanup jobs report healthy execution.
- Database CDC and table CDC are enabled for all six tables.
- Database and table Change Tracking are enabled for the same six tables.
- `change all` advances both heartbeat sequences and creates visible CDC scan activity.
- `reset all` is repeatable and restores the baseline without disabling tracking.
- Diagnostics expose heartbeat age, CDC errors/sessions, memory pressure, and log utilization.
- The `fabriccdc` login can connect privately and read the source and CDC schemas required by the Fabric connector.

## Review stop

Review the schema, seed semantics, permissions, credential path, mutation behavior, and diagnostics before Phase 3. Do not create Fabric streaming or landing assets as part of this phase.
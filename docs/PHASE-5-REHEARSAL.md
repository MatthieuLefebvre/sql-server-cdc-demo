# Phase 5 - Demo rehearsal

## Status

The live two-instance operational rehearsal passed on 2026-08-26 with zero acceptance failures. It reconciled Fabric, validated the baseline, reset both SQL sources, emitted one deterministic transaction per source, proved both new heartbeat events landed with the correct identity, and reran the full topology and OneLake health checks.

The run took 237.3 seconds. SQL reset completed in 127.4 seconds, below the ten-minute reset gate.

An isolated empty-to-live rehearsal also passed on 2026-08-26. It created a temporary workspace, workspace identity, scoped VNet role, Eventhouse, KQL database, two Eventstreams, and Queryset; proved fresh identity-safe landing and drained OneLake mirroring; then removed the workspace, generated files, and temporary role assignment. The validated demo workspace was never modified or deleted.

## Rehearsal commands

Run from PowerShell at the repository root after Azure CLI sign-in:

```powershell
.\scripts\invoke-phase5-rehearsal.ps1 -Mode Plan
.\scripts\invoke-phase5-rehearsal.ps1 -Mode Apply
```

Run the destructive creation rehearsal only through the guarded disposable lifecycle:

```powershell
.\scripts\manage-disposable-fabric.ps1 -Mode Plan
.\scripts\manage-disposable-fabric.ps1 -Mode Create
.\scripts\apply-phase4.ps1 -Mode Apply -ManifestPath .\config\instances.disposable.json -SkipMirroring
```

After both landing tables materialize, generate a deterministic change, validate its sequence with `validate-phase5.ps1`, and enable mirroring by rerunning `apply-phase4.ps1` without `-SkipMirroring`. Finish with strict validation and cleanup:

```powershell
.\scripts\validate-phase3.ps1 -ManifestPath .\config\instances.disposable.json
.\scripts\manage-disposable-fabric.ps1 -Mode Delete
```

Deletion refuses any workspace whose name does not start with `Fabric RTI Disposable `. It removes the generated workspace-identity VNet role assignment before deleting the workspace, then deletes local disposable state and manifest files.

`Plan` verifies manifest routing and reports proposed Fabric and SQL operations without changing data. `Apply` runs these stages in order:

1. Reconcile manifest-defined Fabric resources and OneLake policies.
2. Validate gateway, connections, Eventstream identity operators, landed mappings, Queryset, and healthy mirroring.
3. Reset mutable SQL demo rows on both VMs.
4. Generate one deterministic transaction and heartbeat sequence `1` on each VM.
5. Require a new landed heartbeat after the rehearsal start time for every expected tenant/source/table mapping.
6. Repeat the full Fabric validation.

The active rehearsal uses `-MirroringMode Healthy`. This requires mirroring to be enabled, 100% complete, free of recorded mirroring failures, and in `Completed` or `PartiallySucceeded` state. The default standalone validator remains stricter and requires a fully drained export with zero latency and pending bytes:

```powershell
.\scripts\validate-phase3.ps1
```

## Measured run

| Stage | Duration | Result |
|---|---:|---|
| Fabric apply | 8.6 s | Six present, zero creates |
| Baseline validation | 13.4 s | Zero failures |
| SQL reset | 127.4 s | Both sources completed |
| Deterministic SQL change | 67.4 s | North and South sequence `1` |
| Freshness validation | 1.4 s | Two new arrivals, zero failures |
| Final validation | 19.1 s | Zero failures |
| Total | 237.3 s | Passed |

Post-run SQL diagnostics also completed on both VMs. The tracked tables remained enabled for both CDC and Change Tracking, capture and cleanup jobs were present, and recent CDC capture sessions reported `error_count = 0`.

## Demo-day sequence

1. Run the rehearsal `Plan` and the strict drained validator before the audience joins.
2. Open both SQL query views, both Eventstreams, the saved `CDC_Isolation_Proof` Queryset, and OneLake files.
3. Follow the timed narrative in `docs/DEMO-PLAN.md`.
4. At the live-change segment, run:

```powershell
.\scripts\invoke-sql-operation.ps1 -Action Change -Mode Apply
```

5. Run the saved isolation Queryset and show the two fixed tenant/source mappings with zero failures.
6. After the session, restore the deterministic baseline:

```powershell
.\scripts\invoke-sql-operation.ps1 -Action Reset -Mode Apply
```

## Failure handling

- A Fabric baseline failure stops before SQL is changed.
- A missing or incorrect identity mapping is a hard stop; do not substitute connector metadata or post-landing enrichment.
- A freshness failure means this rehearsal's CDC event was not proved. Rerun `validate-phase5.ps1` with the original rehearsal start time only after diagnosing connector and capture health.
- A strict mirroring drain failure can be transient during active ingestion. Inspect mirroring statistics and failures; do not present OneLake as current until the strict validator passes.
- Change Tracking remains comparison-only and is never presented as an Eventstream source.

## Empty-to-live result

The clean rehearsal proved:

- Workspace, workspace identity, Eventhouse, and explicit read/write KQL database creation.
- Scoped `Network Contributor` assignment for the temporary workspace identity.
- Fabric `202` polling and operation-result retrieval for Eventhouse, KQL database, Eventstream, Queryset, and identity operations.
- Two source snapshots plus deterministic sequence `4` landing with zero tenant/source failures.
- A second plan with six resources present and zero creates.
- Completed OneLake mirroring with 100% completion, zero latency, and zero pending bytes.
- Complete cleanup: workspace absent, generated files absent, and only the original live workspace VNet role remained.

Operationally, workspace identity/RBAC propagation delayed initial table materialization, and first OneLake exports were staggered. Item creation success is therefore not a readiness signal; fresh-event and strict drained validators remain mandatory.
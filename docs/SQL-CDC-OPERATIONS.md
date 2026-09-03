# SQL Server CDC configuration and ERP impact

This guide explains what this demo changes on SQL Server, where load is introduced, and what must be monitored before the pattern is approved for an ERP production database.

## What CDC does

SQL Server Change Data Capture reads committed changes from the transaction log and writes row images and ordering metadata into relational change tables under the `cdc` schema. Consumers read those change tables without repeatedly scanning the ERP source tables.

For an insert or delete, CDC records one change row. An update normally records a before image and an after image. The metadata includes the commit log sequence number (LSN), intra-transaction ordering, operation code, and changed-column mask.

CDC is distinct from Change Tracking:

| Capability | CDC | Change Tracking |
|---|---|---|
| Captures row values | Yes, including before/after update images | No, primarily key and change metadata |
| Supports ordered replay | Yes, by LSN and sequence | Designed for synchronization queries |
| Used by this Fabric stream | Yes | No, comparison-only |
| Source storage overhead | Change tables and metadata | Smaller tracking metadata |

## Configuration used by the demo

The complete idempotent implementation is in `sql/bootstrap.sql`. At a high level it performs these operations in `VistaERP`:

```sql
USE VistaERP;
EXEC sys.sp_cdc_enable_db;

EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'Projects',
    @role_name = N'cdc_reader',
    @supports_net_changes = 0;
```

The same table-level operation is applied to `Projects`, `JobCosts`, `WorkOrders`, `Equipment`, `Invoices`, and `DemoHeartbeat`. Each source table has a primary key. The deployment also creates a least-privilege `cdc_reader` role and grants the connector the source and CDC access needed by the tested integration.

SQL Server Agent must run continuously. Enabling the first table creates:

- A capture job that invokes the log scan and populates all CDC change tables in that database.
- A cleanup job that advances the retention low watermark and removes expired change rows.

Microsoft documents defaults of up to 1,000 transactions per scan, a five-second wait between scan cycles, daily cleanup at 02:00, three days of retention, and 5,000 rows per cleanup delete. Verify actual values rather than assuming defaults:

```sql
USE VistaERP;
EXEC sys.sp_cdc_help_jobs;
EXEC sys.sp_cdc_help_change_data_capture;
```

Change job settings with `sys.sp_cdc_change_job`, then stop and restart that CDC job for the new values to take effect. Record the old and new settings and test them under representative load.

## ERP performance impact

CDC is asynchronous, but it is not zero cost. The main effects are:

1. **Transaction log work.** Normal DML is already logged. The capture process subsequently scans log records. If capture stops or falls behind, the log truncation point cannot advance past uncaptured changes, even in simple recovery.
2. **Database writes and storage.** CDC writes change rows and LSN mapping records. Wide tables, updates that generate two row images, high transaction rates, and long retention increase I/O and storage.
3. **SQL Agent CPU and I/O.** The capture job scans and commits batches continuously. Aggressive polling reduces latency but can increase wakeups and sustained source load.
4. **Cleanup work.** Retention cleanup issues deletes against change tables. Large backlogs or poorly timed cleanup can create I/O, logging, and blocking pressure.
5. **Consumer load.** Connectors querying CDC tables consume CPU, memory, and I/O. Multiple independent consumers can multiply this work.
6. **DDL and upgrades.** CDC records relevant DDL history. SQL Server servicing can upgrade internal CDC objects and may use substantial log space when change tables are large.

The expected ERP response-time impact is workload-specific. A small number of narrow, moderately changing tables often has modest overhead; large transactions, wide rows, heavy update rates, constrained log I/O, or a lagging capture process can make the effect material. Do not use a fixed percentage from another system as an acceptance criterion.

## Preproduction acceptance test

Run a replay or load test using representative peak and normal periods. Compare a baseline with CDC disabled against CDC enabled and an active consumer.

Measure at least:

- ERP transaction latency at p50, p95, and p99, plus timeout and deadlock rates.
- Batch duration and throughput for critical posting, invoicing, and maintenance operations.
- CPU, data-file IOPS/latency, log write latency, memory grants, and wait statistics.
- Transaction-log used percentage, growth events, backup/truncation behavior, and `log_reuse_wait_desc`.
- CDC capture latency, commands per second, errors, and the age of the oldest retained change.
- Change-table growth and cleanup duration.
- End-to-end source commit to dashboard latency.

Define pass/fail thresholds with the ERP owner before testing. Include a capture-job outage long enough to prove alerting, log-growth headroom, restart recovery, and downstream catch-up behavior.

## Monitoring queries

### Database and table state

```sql
SELECT name, is_cdc_enabled
FROM sys.databases
WHERE name = N'VistaERP';

USE VistaERP;
SELECT s.name AS schema_name, t.name AS table_name, t.is_tracked_by_cdc
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_tracked_by_cdc = 1
ORDER BY s.name, t.name;
```

### Capture health and latency

```sql
SELECT TOP (20)
    session_id,
    start_time,
    end_time,
    duration,
    scan_phase,
    error_count,
    command_count,
    latency,
    empty_scan_count
FROM sys.dm_cdc_log_scan_sessions
ORDER BY session_id DESC;

SELECT TOP (20) *
FROM sys.dm_cdc_errors
ORDER BY entry_time DESC;
```

For the aggregate row where `session_id = 0`, Microsoft defines latency as the elapsed time between source commit and the last captured transaction being committed to the change table. Throughput can be estimated from `command_count / duration` when duration is nonzero.

### Transaction-log risk

```sql
SELECT
    name,
    recovery_model_desc,
    log_reuse_wait_desc
FROM sys.databases
WHERE name = N'VistaERP';

USE VistaERP;
SELECT
    total_log_size_mb,
    active_log_size_mb,
    log_truncation_holdup_reason
FROM sys.dm_db_log_stats(DB_ID());
```

Alert when the capture job is not running, CDC errors appear, lag breaches the recovery objective, log utilization grows unexpectedly, cleanup fails, or a consumer approaches the retention low watermark.

## Tuning principles

- Capture only columns and tables with a justified downstream use. Row width is paid again in change storage and transport.
- Keep source transactions reasonably sized. Large transactions delay visibility until commit and create larger capture bursts.
- Size log files for normal peaks plus a tested capture outage. Use fixed growth increments and monitor storage headroom.
- Set retention longer than the maximum credible consumer outage and recovery time, with safety margin. Longer retention costs storage and cleanup work.
- Change `maxtrans`, `maxscans`, and polling interval only after measuring both capture lag and ERP pressure. The theoretical continuous-mode ceiling with a nonzero interval is approximately `(maxtrans * maxscans) / polling_interval` transactions per second, but actual throughput also depends on row width, I/O, and transaction shape.
- Schedule or tune cleanup away from known ERP peaks when evidence shows contention. Do not disable cleanup without a replacement retention process and alerting.
- Avoid routine stop/start scheduling as a substitute for capacity planning. Temporarily stopping capture can move work away from a peak, but log retention and catch-up load still need explicit bounds.
- Validate interactions with transactional replication, availability groups, backup, recovery, and the ERP vendor's support policy.

## Schema evolution

Adding a source column does not automatically add it to an existing CDC capture instance. The existing change table preserves its original shape and ignores newly added, uncaptured columns.

The demo uses SQL Server's supported overlap pattern:

1. Add the source column.
2. Create a second capture instance that includes the new shape.
3. Run both capture instances concurrently while downstream consumers are updated and validated.
4. Switch consumers only after the new timeline covers the handoff point.
5. Retire the old instance after the rollback window.

A source table can have at most two concurrent capture instances, so schema transitions must be planned and completed. See `sql/schema-drift-add.sql` and the schema drift runbook in `docs/MEDALLION-DEMO.md`.

## Operational ownership

Production approval should name owners for SQL Agent health, transaction-log capacity, CDC retention, connector recovery, downstream replay, schema changes, and incident communication. The ERP DBA must be able to stop the consumer without disabling CDC, recover from connector downtime within retention, and prove that no LSN range was skipped.

## Microsoft references

- [What is change data capture?](https://learn.microsoft.com/sql/relational-databases/track-changes/about-change-data-capture-sql-server)
- [Enable and disable change data capture](https://learn.microsoft.com/sql/relational-databases/track-changes/enable-and-disable-change-data-capture-sql-server)
- [Administer and monitor change data capture](https://learn.microsoft.com/sql/relational-databases/track-changes/administer-and-monitor-change-data-capture-sql-server)
- [`sys.sp_cdc_change_job`](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sys-sp-cdc-change-job-transact-sql)
- [`sys.dm_cdc_log_scan_sessions`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/change-data-capture-sys-dm-cdc-log-scan-sessions)

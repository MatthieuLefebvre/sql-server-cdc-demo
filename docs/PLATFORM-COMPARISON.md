# Fabric RTI, Kafka with Debezium, and Databricks

This comparison is for SQL Server CDC pipelines that must preserve source identity, process changes continuously, and serve operational analytics. It is not a benchmark and does not claim that one platform is universally faster or cheaper.

The alternatives are not exact substitutes:

- **Microsoft Fabric Real-Time Intelligence (RTI)** is an integrated managed experience for ingestion, event processing, Eventhouse analytics, dashboards, alerts, OneLake, and broader Fabric consumption.
- **Kafka with Debezium** is a portable CDC event-log architecture. Kafka provides durable partitioned streams; Debezium turns database logs into change events. Analytics, dashboards, governance, and operations are assembled from additional components.
- **Databricks** provides managed lakehouse engineering, Spark Structured Streaming, SQL, governance, and ML. A database CDC connector or log broker is commonly paired with it when the source is SQL Server.

## Executive decision view

| Decision factor | Fabric RTI | Kafka + Debezium | Databricks |
|---|---|---|---|
| Fastest path to this demo outcome | Strong when Fabric capacity and skills already exist | More components to assemble | Strong when Databricks is already the engineering standard |
| Durable event-log decoupling | Eventstream/Eventhouse oriented, less Kafka-native control | Core strength with replay and many independent consumers | Usually relies on Kafka/Event Hubs or cloud storage for this role |
| Low-code operational dashboard and alerting | Native strength | Requires separate products | SQL dashboards and alerts available; broader app integration may need more work |
| Complex transformations and ML | Good Fabric-wide options; RTI favors event/time-series analytics | Requires stream processor and ML platform | Core strength with Spark, Delta, SQL, and ML tooling |
| Portability across clouds and runtimes | Microsoft/Fabric centered | Strong open ecosystem, though managed offerings differ | Delta/Spark ecosystem is broad; workspace features are platform-specific |
| Operational surface | Managed and integrated | Highest if self-managed; lower with managed Kafka/connectors | Managed control plane, but streaming jobs and compute still require engineering |
| Cost shape | Shared Fabric capacity plus storage | Brokers, connectors, networking, storage, and every consuming platform | DBUs plus cloud compute/serverless, storage, and ingress layer |

## Performance

### Latency

Fabric RTI is designed for event-driven ingestion and seconds-to-insight operational analytics. This demo uses direct SQL CDC ingestion, streaming transformations, update policies, and a dashboard on the same platform, which removes several cross-service handoffs. Actual latency still depends on the source CDC scan, connector behavior, Eventhouse ingestion, capacity pressure, query design, and dashboard refresh.

Kafka and Debezium can deliver low-latency ordered events with explicit partitioning, retention, and consumer offsets. They are often the strongest fit when many independent applications need replayable database events. End-to-end insight latency includes the chosen stream processor, sink, query engine, and dashboard rather than Kafka alone.

Databricks Structured Streaming is a fault-tolerant incremental engine. Conventional Structured Streaming is commonly micro-batch based; trigger interval, batch size, state, checkpointing, and compute determine latency. Databricks also offers specialized real-time processing capabilities, but eligibility, limitations, and cost must be validated for the workload. For a straightforward operational dashboard, Spark may add machinery; for complex stateful transformations, enrichment, and ML, that machinery can be valuable.

### Throughput and scaling

- Fabric scales through capacity and workload management. Shared capacity is convenient, but concurrent BI, Spark, warehouse, and RTI work can compete. Use the Capacity Metrics app, surge protection/workspace controls where available, and separate capacities when isolation objectives require it.
- Kafka scales primarily through partitions, broker capacity, and consumer parallelism. It gives precise control but partition-key mistakes, hot partitions, replication, rebalancing, and connector task sizing become engineering responsibilities.
- Databricks scales Spark processing horizontally and is well suited to heavy transformations. Stateful streams, skew, shuffles, checkpoint growth, and large micro-batches need tuning. Databricks recommends production jobs, automatic restart, and its managed pipeline options for new pipelines rather than treating a notebook as an always-on service.

No platform should be selected from vendor maximums. Benchmark the full path using representative transaction sizes, update ratios, schema changes, burst patterns, retained history, query concurrency, and failure recovery.

## Cost

### Fabric RTI cost shape

Fabric capacity is a shared pool of Capacity Units used by multiple workloads. This can be economically attractive when an organization already owns underused capacity and wants ingestion, analytics, dashboarding, and action on one platform. The same sharing can obscure marginal workload cost and create contention. OneLake and Eventhouse cache/storage charges, Power BI author licensing where applicable, network charges, and source infrastructure remain relevant.

The correct model includes:

- Required steady and peak Fabric SKU or pay-as-you-go capacity.
- RTI ingestion, Eventhouse processing/query concurrency, and dashboard load.
- OneLake storage, KQL cache, retention, and duplicate data outside OneLake.
- Capacity overage or a separate capacity for guaranteed isolation.
- Existing capacity commitments that change the marginal cost.

### Kafka and Debezium cost shape

Open-source software has no license fee, but the platform is not free. A production estimate includes:

- Kafka brokers or managed Kafka units, replicated storage, retention, and cross-zone/region transfer.
- Kafka Connect/Debezium workers, schema registry, monitoring, security, patching, backup, and disaster recovery.
- A stream processor or sink connector and the analytics database/lakehouse.
- Dashboard, alerting, catalog/governance, and on-call engineering.

Kafka can be cost-effective when one durable event backbone serves many teams and use cases, amortizing its fixed platform cost. It can be disproportionately expensive for one small pipeline if the organization does not already operate it. Azure Event Hubs exposes a managed Kafka endpoint and can reduce broker operations, but its quotas, feature differences, throughput-unit or processing-unit pricing, retention, and event charges must be included.

### Databricks cost shape

Azure Databricks charges depend on workload type and DBU consumption, plus underlying cloud compute for nonserverless options, storage, networking, and the CDC ingestion layer. Continuous jobs can hold compute for long periods; job compute, managed pipelines, serverless eligibility, autoscaling behavior, and latency requirements materially affect cost.

Databricks can consolidate value when the same platform already supports batch engineering, streaming, SQL, governance, and ML. It may cost more than an integrated RTI path for a narrow live dashboard, but can cost less than operating parallel specialist systems when transformation complexity and reuse are high.

### Compare total cost, not list-price units

Build three workload-specific estimates over the same period and service level. Include platform engineering, 24x7 operations, recovery testing, nonproduction environments, retention, network transfer, observability, security, licenses, and idle/peak compute. Price units such as Fabric CUs, Kafka throughput units, and Databricks DBUs are not directly comparable.

## Reliability and operations

| Concern | Fabric RTI | Kafka + Debezium | Databricks |
|---|---|---|---|
| Source offset/position | Managed connector state; validate recovery behavior | Explicit connector offsets and Kafka consumer offsets | Checkpoints plus source-specific offsets |
| Delivery semantics | Design consumers to tolerate duplicates | Typically at-least-once end to end; stronger guarantees depend on configuration and sinks | Exactly-once processing is available for supported sources/sinks; `foreachBatch` is at-least-once unless made idempotent |
| Replay | Retained Eventhouse/raw data and source retention define options | Native retained-log strength | Checkpoints and Delta history; upstream log often provides independent replay |
| Failure ownership | Fabric service plus capacity/workspace operations | Broker, Connect, Debezium, schemas, sinks, and consumers | Jobs/pipelines, checkpoints, compute, libraries, and upstream ingestion |
| Schema evolution | Eventstream contracts plus dynamic bronze and typed downstream controls | Schema registry and connector compatibility policy are common | Delta/Lakeflow schema controls and pipeline restart behavior |

Whichever platform is chosen, preserve a raw immutable layer, make downstream writes idempotent, monitor source lag against retention, and test restart from a known source position.

## Source identity and multitenancy

The deciding requirement in this project is not merely moving changes; it is proving which independent ERP instance produced every row.

In Fabric, multiple sources entering one Eventstream are merged before downstream operators in the tested topology. Therefore this project uses one ingress Eventstream per source to add fixed `tenant_id` and `source_instance` values before both streams land in shared bronze.

With Debezium, source metadata is normally part of each change-event envelope. Govern topic naming, connector configuration, and immutable source fields so consumers do not infer tenancy from mutable business data.

With Databricks, carry source identity from the ingestion layer into every bronze record and include it in merge keys, checkpoints, quality rules, and access policies. Do not derive it only after unrelated source feeds have been unioned.

## When each option is a strong fit

Choose **Fabric RTI** when the primary goal is rapid operational insight and action in a Microsoft data estate, teams want low-code and KQL experiences, Fabric capacity already exists, and an integrated path from source through dashboard reduces operational burden.

Choose **Kafka with Debezium** when CDC events are a shared product for many independent consumers, long replay windows and event-log semantics are central, cross-platform portability matters, and the organization already has Kafka platform expertise or a suitable managed service.

Choose **Databricks** when streaming is part of a broader lakehouse engineering and ML program, transformations are complex or stateful, Delta and Unity Catalog are standards, and the team is equipped to operate production streaming jobs and their compute economics.

A hybrid can be correct: Debezium to Kafka or Event Hubs for reusable transport, with Fabric RTI for operations and Databricks for advanced engineering. The tradeoff is extra copies, network paths, failure modes, governance boundaries, and cost.

## Evaluation scorecard

Before selecting a platform, assign weights and measured evidence to:

1. Source-to-action latency objective and allowed jitter.
2. Average, peak, and burst event rates; transaction and row sizes.
3. Number and independence of consumers; replay and retention requirements.
4. Transformation complexity, state, joins, ML, and data-quality rules.
5. Existing contracts, capacity, skills, support model, and 24x7 ownership.
6. Security, private networking, data residency, lineage, and access isolation.
7. Recovery-point and recovery-time objectives with tested failure scenarios.
8. Three-year total cost at normal, peak, and growth cases.

## References

- [Microsoft Fabric Real-Time Intelligence overview](https://learn.microsoft.com/fabric/real-time-intelligence/overview)
- [Microsoft Fabric pricing](https://azure.microsoft.com/pricing/details/microsoft-fabric/)
- [Apache Kafka protocol support in Azure Event Hubs](https://learn.microsoft.com/azure/event-hubs/azure-event-hubs-apache-kafka-overview)
- [Azure Event Hubs pricing](https://azure.microsoft.com/pricing/details/event-hubs/)
- [Debezium SQL Server connector](https://debezium.io/documentation/reference/stable/connectors/sqlserver.html)
- [Azure Databricks Structured Streaming](https://learn.microsoft.com/azure/databricks/structured-streaming/)
- [Production considerations for Structured Streaming](https://learn.microsoft.com/azure/databricks/structured-streaming/production)
- [Azure Databricks pricing](https://azure.microsoft.com/pricing/details/databricks/)
# Architecture Decision Records — Auto Project

Auto Project | Automotive Retail Analytics Platform  
Last updated: February 2026

---

## What Is This File?

An Architecture Decision Record (ADR) captures a significant technical decision , the context that created the need for a decision, the options that were considered, what was chosen, and why. The goal is not to justify every choice but to make the reasoning visible so that anyone maintaining or extending this platform understands the intent behind each design.

Each record has a status:
- **Accepted** — decision is in effect
- **Superseded** — replaced by a later decision (linked)
- **Proposed** — under consideration, not yet implemented

---

## ADR-001: CDC Handled in Snowflake, Not dbt

**Date:** January 2026  
**Status:** Accepted

### Context

The pipeline needed incremental processing — a way to avoid re-scanning entire landing tables on every run as data volume grows. Two approaches were available: dbt incremental models, or Snowflake-native Streams and Tasks.

### Options Considered

**Option A — dbt incremental models**  
dbt supports incremental materialisation where models append only new records using a watermark (e.g. `loaded_at > last_run`). This keeps all transformation logic in one tool and is the more common approach in dbt-first pipelines.

The problem: dbt incremental models still need to read from the source table to find new records. The watermark logic adds boilerplate to every model. And dbt incremental models were never designed to handle deduplication — they append, they don't resolve. Any deduplication would require additional complexity inside dbt itself.

**Option B — Snowflake Streams + Tasks (chosen)**  
Snowflake Streams attach to a landing table and track changes natively at the database level. A Stream is a cursor — it knows exactly which rows have changed since it was last consumed, without scanning the whole table. Tasks consume the stream and write clean records to Silver.

### Decision

Snowflake Streams and Tasks handle CDC and light standardisation. dbt reads from clean Silver tables and is never responsible for tracking which records it has already processed.

### Consequences

- dbt models are simpler and more readable — no incremental watermark logic, no deduplication boilerplate
- The transformation layer is split across two tools (Snowflake for technical concerns, dbt for business logic), which requires understanding both to maintain the pipeline
- Streams must be consumed on a schedule — if the Task fails and the stream is not consumed, Snowflake retains change records for up to 14 days (Extended Data Retention) before they expire

---

## ADR-002: Snowflake Over Databricks

**Date:** January 2026  
**Status:** Accepted

### Context

Two cloud warehouse platforms were viable for this project: Snowflake and Databricks. The choice had downstream implications for everything — ingestion, compute, modeling, cost, and the BI connection.

### Options Considered

**Option A — Databricks**  
Databricks is a strong platform, particularly for ML workloads, Python-heavy transformation, and large-scale streaming. Delta Lake's native ACID transactions and time-travel are genuinely useful capabilities. It is the better choice for data science and ML engineering teams who need unified compute across notebooks and pipelines.

**Option B — Snowflake (chosen)**  
Snowflake is SQL-first, storage and compute are fully separated, and the platform is purpose-built for analytics delivery rather than ML experimentation. Snowpipe, Streams, Tasks, and Stages are native features that require no additional infrastructure to configure. The IAM role-based external stage integration with S3 is straightforward and secure.

### Decision

Snowflake. The primary consumers of this platform are analysts and BI tools — not data scientists or ML engineers. Snowflake's SQL interface, native ingestion primitives (Snowpipe, Streams), and tight Power BI integration made it the right fit for a governed analytics delivery use case.

### Consequences

- Snowflake's per-credit compute model is cost-predictable at X-Small warehouse size for this volume
- CDC via Streams is a native Snowflake feature — this decision and ADR-001 are directly linked
- Databricks would be the better choice if ML forecasting (flagged as a future improvement) becomes the primary use case

---

## ADR-003: dbt Reads from Silver, Not Bronze

**Date:** January 2026  
**Status:** Accepted

### Context

dbt could be pointed at Bronze landing tables and handle all transformation itself — cleaning, deduplication, type casting, and business logic. This is a common pattern in simpler pipelines.

### Options Considered

**Option A — dbt reads from Bronze**  
Simpler setup. Everything in dbt. But this means dbt models must handle raw VARCHAR types, null handling, deduplication, and business logic in the same layer. Models become harder to read and harder to test, because technical concerns are mixed with business concerns.

**Option B — dbt reads from Silver (chosen)**  
Snowflake Tasks handle the technical layer (dedupe, types, nulls, casing) before dbt ever sees the data. dbt reads from clean, typed Silver tables and focuses exclusively on business logic and dimensional modeling.

### Decision

dbt reads from Silver. The rule is: technical concerns belong in Snowflake, business concerns belong in dbt.

### Consequences

- dbt models express business intent clearly — a reviewer can read `orders_fact` and understand what it represents without parsing type-casting logic
- dbt tests run against typed, clean data — a `not_null` test on `order_id` means something, because nulls would have been handled upstream
- Two tools own two layers of transformation, which increases maintenance surface — a developer joining the project must understand both

---

## ADR-004: `orders_fact` as the Central Fact, Downstream Facts Derived From It

**Date:** January 2026  
**Status:** Accepted

### Context

`store_sales_fact` and `customer_revenue_fact` both aggregate revenue data that is already calculated in `orders_fact`. The question was whether to build them independently from staging, or to derive them from `orders_fact`.

### Options Considered

**Option A — All facts read from staging independently**  
Each fact table joins staging models itself. More compute, but avoids a dependency between Gold models.

**Option B — Downstream facts read from `orders_fact` (chosen)**  
`store_sales_fact` and `customer_revenue_fact` use `{{ ref('orders_fact') }}` as their source. The revenue calculations (`net_order_revenue`, `cancelled_order_value`, `gross_order_value`) are defined once in `orders_fact` and reused downstream.

### Decision

`orders_fact` is the single source of truth for order-level revenue. Downstream facts (`store_sales_fact`, `customer_revenue_fact`) derive from it. Business metric definitions are written once, not duplicated.

### Consequences

- A fix to cancellation logic in `orders_fact` automatically propagates to `store_sales_fact` and `customer_revenue_fact` on the next dbt run
- `product_sales_fact` is an exception — it reads from staging directly because it needs line-item quantity (`order_items_stg.quantity`) that is aggregated away in `orders_fact`. This inconsistency is documented in LINEAGE.md as a known gap
- dbt's dependency graph correctly shows `store_sales_fact` and `customer_revenue_fact` downstream of `orders_fact` — the lineage DAG reflects reality

---

## ADR-005: Power BI Import Mode Over DirectQuery

**Date:** February 2026  
**Status:** Accepted

### Context

Power BI offers two primary data connection modes: DirectQuery (queries run against Snowflake in real time on every report interaction) and Import Mode (data is loaded into Power BI's in-memory engine on a schedule).

### Options Considered

**Option A — DirectQuery**  
Every slicer interaction, page load, or filter triggers a live SQL query against Snowflake. Data is always current. But: every analyst interaction consumes Snowflake credits. On an X-Small warehouse with multiple concurrent report users, this creates unpredictable cost and query contention.

**Option B — Import Mode + Incremental Refresh (chosen)**  
Data is loaded into Power BI's engine on a scheduled refresh. Snowflake is only queried at refresh time, not on every report interaction. Incremental Refresh means only recently changed date partitions are reloaded — the full dataset is not re-imported every time.

### Decision

Import Mode with Incremental Refresh. The platform is designed for governed, cost-efficient analytics delivery — not real-time operational monitoring. A scheduled refresh cadence (e.g. every 4 hours) is acceptable for all dashboard audiences.

### Consequences

- Snowflake credit consumption is predictable and low — queries run on a schedule, not on-demand
- Report interactions are fast — Power BI's Vertipaq engine handles filtering and aggregation in memory
- Data is not real-time — a report user may see data that is up to 4 hours old. This is an accepted trade-off for this use case
- If real-time SLA monitoring becomes a requirement, DirectQuery on a dedicated Snowflake warehouse (separate from the transformation warehouse) would be the right approach

---

## ADR-006: Gold-Only Exposure to Power BI

**Date:** February 2026  
**Status:** Accepted

### Context

Power BI could be connected to any layer — Bronze, Silver, or Gold. Technically there is nothing stopping an analyst from querying `raw_orders` directly.

### Options Considered

**Option A — Expose all layers**  
More flexibility. Analysts can explore raw data. But: metric definitions diverge, undeduped Bronze data enters dashboards, Silver tables (designed for dbt consumption, not BI) are used for executive reporting.

**Option B — Gold only (chosen)**  
Power BI connects exclusively to Gold mart tables. Raw and Silver layers are not exposed. Metric definitions are enforced at the Gold layer and cannot be bypassed.

### Decision

Gold-only exposure. The contract between the data platform and its consumers is the Gold layer. Business definitions of net revenue, cancelled revenue, and SLA metrics are enforced at that boundary and nowhere else.

### Consequences

- All dashboards use the same metric definitions — a "net revenue" figure in the Executive Overview and the Store Performance dashboard are calculated from the same source
- Analysts cannot accidentally query undeduped Bronze data
- If an analyst needs data that is not in Gold (e.g. a raw field that was not surfaced in any mart), a new Gold model or column must be added — this is a deliberate friction point to keep the Gold layer complete and governed

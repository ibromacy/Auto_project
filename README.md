# 🚗 Auto Project — End-to-End Modern Data Platform
### Automotive Retail Analytics | Snowflake · dbt Core · Airflow · Power BI

---

## 📌 Overview

This project is a production-style analytics platform built for a UK automotive retail business — covering orders, customers, stores, products, SLA, and delivery performance. It is not a tutorial or a guided walkthrough. Every architectural decision was made deliberately, with a real constraint or tradeoff in mind.

The platform answers a specific question: **how do you go from raw operational data landing in cloud storage to governed, stakeholder-ready analytics  without full-table scans, without duplicate transformation logic, and without blowing up warehouse costs?**

The answer is a layered architecture where each component owns a clearly defined responsibility:

- **AWS S3** — raw file storage, structured by domain
- **Snowpipe** — event-driven auto-ingestion, no scheduled load jobs
- **Snowflake Streams + Tasks** — CDC and light standardisation before any business logic runs
- **dbt Core** — Kimball dimensional modeling, data quality enforcement, documentation
- **Apache Airflow** — orchestration with success/failure alerting via Slack
- **Power BI** — audience-specific dashboards, Import Mode + Incremental Refresh for cost control

 ![architecture Diagram](assets/architecturess.png)
                              
>  — a single-flow diagram showing S3 → Snowpipe → Bronze/Silver/Gold → Airflow → Power BI. 

---

## 🧠 Business Context

The platform was built around real commercial questions that an automotive retailer would actually ask. The schema — orders, order items, customers, stores, regions, products, SLA, and regional targets  was designed to support those questions not the other way around.

**Questions the platform is built to answer:**

| Business Question | Fact Table | Key Dimensions |
|---|---|---|
| Which stores generate the highest net revenue? | `store_sales_fact` | `dim_store`, `dim_date` |
| How much revenue is lost to cancellations? | `orders_fact` | `dim_customers`,`dim_store`, `dim_date` |
| What is SLA on-time delivery performance by region? | `orders_fact` | `dim_store`, `dim_date` |
| Which products drive seasonal peaks? | `product_sales_fact` | `dim_product`, `dim_date` |
| How does store revenue track against monthly targets? | `store_sales_fact` | `dim_store`, `dim_date` |
| What is customer churn rate over time? | `customer_revenue_fact` | `dim_customer`, `dim_date` |

Cancelled revenue is tracked separately from net revenue throughout the model — inflating net figures with cancellations is a common modeling mistake that makes executive dashboards misleading. Isolation was a deliberate grain decision to have same metric definition across semantic layers, not an afterthought.


---

## 🏗 Architecture & Key Design Decisions

 ![s3integration Diagram](assets/s3integrations.png) 

### Why Snowflake

The platform was designed for analytics delivery, not data science or ML experimentation. Snowflake's separation of storage and compute, native support for semi-structured data and first-class SQL interface made it the right fit for a use case where the primary consumers are analysts and BI tools  not notebooks or machine learning pipelines. Databricks is a strong platform, but its strengths are better matched to engineering-heavy, ML-centric workloads. For governed analytics delivery on a star schema, Snowflake is the cleaner choice.

### Why CDC in Snowflake, not dbt

The tempting approach is to handle everything in dbt — incremental models, deduplication, the lot. The problem is that dbt's incremental logic runs on a schedule, re-reads source tables to find new records, and adds complexity to models that should be focused on business logic.

Snowflake Streams solve this natively. A stream attached to a landing table captures only the rows that have changed since the last time it was consumed. No re-scanning. No watermark management. No incremental model boilerplate in dbt. When the Task runs, it processes the change set and writes clean records into Silver and dbt never has to think about whether it's seen a record before.

The result is dbt models that are genuinely readable: they express business logic, not pipeline mechanics.

### Why technical transforms happen before dbt

dbt's job in this platform is dimensional modeling and business logic. It should not be doing deduplication or type casting — those are data engineering concerns, not analytics concerns.
Snowflake Tasks run every 5 minutes and handle:
- Deduplication based on business keys and latest timestamp
- Type standardisation (dates, nulls, casing)
- Writing clean Silver tables that dbt reads from

This keeps the Silver → Gold boundary clean. Anyone reading a dbt model sees business intent, not plumbing.

### Why IAM role-based auth, not access keys

Static access keys stored in code or environment variables are a security liability they can be leaked, they don't expire automatically and they're hard to rotate at scale. Snowflake's Storage Integration uses a trust relationship between Snowflake's AWS account and your S3 bucket scoped to a specific external ID. No credentials are stored anywhere in the codebase.

---

## 🧱 Tech Stack

| Layer | Tool | Rationale |
|---|---|---|
| Cloud Storage | AWS S3 | Structured domain layout, native Snowpipe event trigger |
| Data Warehouse | Snowflake (X-Small) | Separation of storage/compute, SQL-first, analytics-optimised |
| Ingestion | Snowpipe (auto-ingest) | Event-driven, no scheduled load jobs, per-file traceability |
| CDC + Standardisation | Snowflake Streams + Tasks | Native CDC without full-table scans, keeps dbt focused |
| Transformation | dbt Core | Business logic, Kimball modeling, testing, documentation |
| Orchestration | Apache Airflow (Docker) | Dependency management, local production parity, portable |
| BI | Power BI | Import Mode + Incremental Refresh, audience-specific delivery |
| Monitoring | Slack webhooks | Real-time success/failure alerting per DAG run |
| Version Control | Git + GitHub | Full commit history, future CI/CD hook point |

---

## 🔄 Ingestion & CDC

### S3 Bucket Layout

Raw CSV extracts land in a domain-separated structure:

```
s3://<bucket>/raw/customers/
s3://<bucket>/raw/orders/
s3://<bucket>/raw/order_items/
s3://<bucket>/raw/products/
s3://<bucket>/raw/stores/
```

Domain separation matters here for two reasons: it makes Snowpipe event routing straightforward (each pipe watches one prefix), and it means a new data source can be onboarded without touching the layout of existing ones.

### Snowflake–S3 Integration (IAM Role–Based)

Access is configured via a Snowflake Storage Integration — a trust relationship between Snowflake and the S3 bucket using an external ID. No static credentials exist in the codebase or environment. This is the correct approach for any production Snowflake deployment.

The setup per source follows a consistent pattern:

1. Create a Landing Table (Bronze entry point, all columns as VARCHAR)
2. Define a File Format (delimiter, date parsing, null handling)
3. Create an External Stage (S3 path + integration + file format)
4. Create a Pipe (auto-ingest from stage into landing table)
5. Validate via `PIPE_STATUS` to confirm files are being processed

### Streams + Tasks (CDC → Silver)

A Snowflake Stream is attached to each landing table immediately after creation. The stream captures inserts and updates as a change record set only what has changed since the last consumption, nothing more.

A Snowflake Task runs every 5 minutes. For each source it:
1. Reads the stream's change records
2. Deduplicates on business key + latest timestamp
3. Applies light standardisation (types, nulls, casing)
4. Writes clean records into the corresponding Silver table

If no new files have landed, the stream is empty and the Task completes instantly. No compute is wasted re-reading unchanged data.

 ![Streams Diagram](assets/streams&task.png)

---

## 🧪 dbt Transformation & Modeling

 ![data_lineage Diagram](assets/data_lineage.png)

### Medallion Layers

| Layer | Owner | Content |
|---|---|---|
| Bronze | Snowpipe | Raw landing tables — unmodified source data, VARCHAR columns |
| Silver | Snowflake Tasks | Cleaned, typed, deduped — technical concerns resolved |
| Gold | dbt Core | Facts and dimensions — business logic, Kimball modeling |

dbt reads from Silver. It never touches Bronze. This boundary is intentional dbt models express business logic, and business logic should start from clean data.

### Kimball Star Schema

Gold layer models follow Kimball dimensional modeling conventions with strict grain discipline.

**Fact Tables (atomic grains):**

| Table | Grain | Description |
|---|---|---|
| `orders_fact` | 1 row per order | Order-level revenue, status, cancellation flag |
| `store_sales_fact` | 1 row per store per day | Aggregated daily revenue per store vs target |
| `product_sales_fact` | 1 row per product per day | Daily product volume and revenue |
| `customer_revenue_fact` | 1 row per customer | Lifetime value, order count, churn indicators |

**Dimension Tables:**

| Table | Description |
|---|---|
| `dim_date` | Calendar attributes — day, week, month, quarter, year |
| `dim_store` | Store name, region, area manager |
| `dim_product` | Product name, category, subcategory |
| `dim_customer` | Customer name, region, acquisition channel |

**Cancelled revenue** is tracked as a separate field on `orders_fact` rather than excluded or negated. This means net revenue and gross revenue can both be calculated from the same fact table without double-counting or misleading aggregations.

### Data Quality

dbt tests enforce data quality at the Gold layer on every run.

| Test Type | What It Catches |
|---|---|
| `not_null` | Missing values on non-nullable keys and measures |
| `unique` | Duplicate rows violating grain definitions |
| `accepted_values` | Invalid status codes, unexpected categorisations |
| Singular: revenue sanity | Net revenue and gross order value are never zero or negative |

Test failures block downstream models from building. A broken dimension does not silently corrupt a fact table.

---

## ⚙️ Orchestration

 ![Dag Diagram](assets/dag.png)

Airflow runs in Docker for local production parity. The DAG triggers `dbt build` (which runs models and tests together), routes to success or failure notification, and sends a Slack alert either way.

**Current pipeline:**
```
dbt build (models + tests) → branch → notify_success
                                   └──► notify_failure
```

**Planned production pipeline:**
```
Snowflake freshness check → dbt build → Power BI dataset refresh → Slack alert
```

The freshness check is the missing piece that would make this genuinely watermark-driven — only running dbt if new data has actually landed. This is the highest-priority production improvement.

---

## 📊 Power BI Delivery

 ![Executive Diagram](assets/executive_overview2025.png)

Power BI connects only to Gold mart tables. Raw and Silver layers are never exposed to BI tools ,this is a deliberate governance decision that keeps metric definitions consistent and prevents analysts from accidentally querying undeduped or untyped data.

**Performance decisions:**

| Decision | Rationale |
|---|---|
| Import Mode | Eliminates repeated Snowflake queries during report interaction — credits only spent on scheduled refresh |
| Incremental Refresh | Date-partitioned refresh means only recent partitions reload — avoids full dataset reload on every refresh |
| Gold-only connection | Prevents BI tools from touching Bronze/Silver — cost and governance control |

**Dashboards by audience:**

| Dashboard | Primary Audience | Key Questions |
|---|---|---|
| Executive Overview | Leadership | Revenue trend, SLA% , cancellation rate |
| Store Performance | Regional managers | Revenue by store, regional comparison |
| Product Performance | Product & marketing | Top products, seasonal trends, category mix |
| Customer & Sales | Commercial teams | Top Customers , acquisition channel, churn indicators |
| SLA & Operations | Ops stakeholders | On-time delivery rate, SLA breach by region |

---

## 💰 Cost Optimisation

Every layer of this platform has a cost decision built in. This matters on an X-Small Snowflake warehouse where unnecessary compute spend is immediately visible.

| Decision | Cost Impact |
|---|---|
| Snowpipe auto-ingest | Pay per file loaded, not per scheduled job run |
| CDC via Streams | Tasks process only changed rows — compute scales with delta, not table size |
| Tasks handle dedupe/standardisation | Lightweight SQL operations, not full warehouse-scale transforms |
| dbt avoids duplicate incremental logic | No re-scanning of Silver tables for records dbt has already seen |
| Power BI Import Mode | Snowflake is only queried at scheduled refresh time, not on every report interaction |
| Incremental Refresh | Only recent date partitions reload — full dataset refresh avoided |
| Gold-only BI exposure | Analysts cannot accidentally run expensive queries against unoptimised raw tables |

---

## ▶️ Run Locally

**Prerequisites:** Docker Desktop (4GB+ RAM), Git

```bash
# 1. Clone the repo
git clone <repo_url>
cd auto_project

# 2. Start Airflow
docker-compose up -d

# 3. Open Airflow UI
# http://localhost:8080
```


---

## ⚠️ Known Limitations

| Limitation | Detail |
|---|---|
| Mock source data | CSVs are generated to simulate a UK automotive retailer — not live operational data |
| No SCD handling | Dimension tables are full-refresh. Product price changes, store region reassignments, and customer tier changes are not historised. dbt snapshots would be required for Type 2 SCD in production |
| Orchestration gap | Airflow currently triggers dbt on a schedule rather than in response to confirmed data arrival. A Snowflake freshness check before `dbt build` would close this gap |
| Single-node Airflow | LocalExecutor only. A production deployment would use CeleryExecutor or KubernetesExecutor |
| No CI/CD | dbt tests run in the pipeline but not on pull requests. A GitHub Actions workflow running `dbt build --select state:modified+` on PRs would catch regressions before merge |

---

## 🗺 Production Roadmap

These are not gaps — they are the next layer of a production deployment, descoped for this version to keep scope manageable.

1. **Close the orchestration loop** — Snowflake freshness check → dbt build → Power BI dataset refresh → Slack. Makes the pipeline watermark-driven rather than schedule-driven
2. **SCD Type 2 via dbt snapshots** — historise dimension changes so that revenue can be attributed to the correct product price or store region at time of order
3. **CI/CD for dbt** — GitHub Actions running `dbt build --select state:modified+` on every PR. Prevents broken models reaching production
4. **Automated data quality alerting** — surface dbt test failures to Slack in real time rather than requiring manual log inspection
5. **Deploy to MWAA / Astronomer** — move Airflow off Docker onto a managed platform for reliability and scalability

---

## 📁 Supporting Documentation

| File | Contents |
|---|---|
| `DATA_DICTIONARY.md` | Column-level definitions for all Gold mart tables, including grain statements per fact |
| `LINEAGE.md` | Full data lineage from S3 source files to Power BI dashboard fields |
| `ADR.md` | Architecture Decision Records — the reasoning behind CDC placement, dbt layer boundaries, Power BI mode selection, and cost strategy |

---

## 🏆 What This Project Demonstrates

- Production-style modern data platform architecture with real cost and governance constraints
- Cloud-native security — IAM role-based Snowflake–S3 integration, no static credentials
- CDC-first incremental processing — Streams eliminate full-table scans at every layer
- Clean separation of technical transformation (Snowflake) and business logic (dbt)
- Kimball dimensional modeling with grain discipline and metric isolation
- Orchestrated, observable workflows with real alerting
- Stakeholder-led BI delivery with performance and cost decisions built in

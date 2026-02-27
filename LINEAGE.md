# Data Lineage — Auto Project

Auto Project | Automotive Retail Analytics Platform  
Last updated: February 2026

---

## Overview

This document traces how data moves from raw source files in AWS S3 through to Power BI dashboard measures. It covers two things:

1. **Model dependency map** — which dbt models depend on which
2. **Metric-level lineage** — for each key business metric, exactly where it comes from and how it is calculated at each layer

---

## Model Dependency Map

```
AWS S3 (raw CSV files)
    │
    ▼ Snowpipe (auto-ingest)
    │
Snowflake Bronze Layer (landing tables — raw VARCHAR)
    │
    ▼ Snowflake Streams (CDC — inserts & updates only)
    │
    ▼ Snowflake Tasks (every 5 mins — dedupe + standardise)
    │
Snowflake Silver Layer (cleaned, typed, deduped)
    │
    ├── stg_orders ──────────────────────────────────────┐
    │                                                     │
    ├── stg_order_items ──────────────────────────────────┤
    │                                                     │
    └── stg_dates ────────────────────────────────────────┤
                                                          │
                                              ▼ dbt Core
                                        orders_fact  ◄───┘
                                              │
                              ┌───────────────┼───────────────┐
                              │               │               │
                              ▼               ▼               │
                    store_sales_fact  customer_revenue_fact   │
                                                              │
                    order_items_stg ──────────────────────────┘
                    orders_stg                                │
                              │                              │
                              ▼                              │
                    product_sales_fact ◄─────────────────────┘

                              │
                              ▼ Power BI (Gold layer only)
                    Executive Overview
                    Store Performance
                    Product Performance
                    Customer & Sales
                    SLA & Operations
```

### Key dependency notes

- `store_sales_fact` and `customer_revenue_fact` **both read from `orders_fact`**, not from staging. This means a single fix to order-level revenue logic flows automatically to both downstream models.
- `product_sales_fact` reads from `order_items_stg` and `orders_stg` **directly** because it needs  line-item quantity data (`quantity`) that is lost once orders are aggregated in `orders_fact`.
- `orders_fact` is the **only** model that joins all three staging sources (`orders_stg`, `order_items_stg`, `dates_stg`).

---

## Metric Lineage

---

### Net Revenue

The most important business metric. Represents revenue from completed, non-cancelled orders.

```
Source: order_items_stg.line_revenue
    │
    │  Calculated in: orders_fact
    │  Logic: SUM(oi.line_revenue) WHERE cancelled_flag = 0
    │         → stored as orders_fact.net_order_revenue
    │
    ├──► store_sales_fact
    │    Logic: SUM(orders_fact.net_order_revenue) GROUP BY store_id, full_date
    │    Column: store_sales_fact.net_revenue
    │
    ├──► customer_revenue_fact
    │    Logic: SUM(orders_fact.net_order_revenue) GROUP BY customer_id, date_id
    │    Column: customer_revenue_fact.net_revenue
    │
    └──► product_sales_fact
         Logic: SUM(oi.line_revenue) WHERE orders_stg.cancelled_flag = 0
                GROUP BY product_id, date_id
         Column: product_sales_fact.net_revenue
         Note: Calculated independently from staging (not from orders_fact)
               because product-level grain requires line-item detail

Power BI measures:
    [Net Revenue] = SUM(orders_fact[net_order_revenue])
    [Store Net Revenue] = SUM(store_sales_fact[net_revenue])
    [Product Net Revenue] = SUM(product_sales_fact[net_revenue])
    [Customer Net Revenue] = SUM(customer_revenue_fact[net_revenue])
```

---

### Gross Revenue

Total order value before cancellation logic is applied. Always populated regardless of order status.

```
Source: order_items_stg.line_revenue
    │
    │  Calculated in: orders_fact
    │  Logic: SUM(oi.line_revenue) — no cancellation filter
    │         → stored as orders_fact.gross_order_value
    │
    └──► store_sales_fact
         Logic: SUM(orders_fact.gross_order_value) GROUP BY store_id, full_date
         Column: store_sales_fact.gross_revenue

         Also in product_sales_fact:
         Logic: SUM(oi.line_revenue) GROUP BY product_id, date_id
         Column: product_sales_fact.gross_revenue

Identity check: gross_revenue = net_revenue + cancelled_revenue
    This holds at every grain level.
```

---

### Cancelled Revenue

Revenue that was lost due to order cancellation. Tracked explicitly rather than excluded, so that cancellation rate and lost revenue can be analysed.

```
Source: order_items_stg.line_revenue WHERE orders_stg.cancelled_flag = 1
    │
    │  Calculated in: orders_fact
    │  Logic: SUM(oi.line_revenue) WHERE cancelled_flag = 1, ELSE 0
    │         → stored as orders_fact.cancelled_order_value
    │
    ├──► store_sales_fact
    │    Column: store_sales_fact.cancelled_revenue
    │
    ├──► customer_revenue_fact
    │    Column: customer_revenue_fact.cancelled_revenue
    │
    └──► product_sales_fact
         Column: product_sales_fact.cancelled_revenue

Power BI measure:
    [Cancellation Rate] = DIVIDE(SUM([cancelled_revenue]), SUM([gross_revenue]))
```

---

### Cancelled Order Count

```
Source: orders_stg.cancelled_flag
    │
    │  Calculated in: orders_fact
    │  orders_fact.cancelled_flag = 1 (row-level flag)
    │
    ├──► store_sales_fact
    │    Logic: SUM(CASE WHEN cancelled_flag = 1 THEN 1 ELSE 0 END)
    │    Column: store_sales_fact.cancelled_orders
    │
    └──► customer_revenue_fact
         Logic: SUM(CASE WHEN cancelled_flag = 1 THEN 1 ELSE 0 END)
         Column: customer_revenue_fact.cancelled_orders
```

---

### SLA Status / On-Time Delivery Rate

```
Source: orders_stg.sla_status
    │
    │  Passed through in: orders_fact
    │  Column: orders_fact.sla_status (VARCHAR — 'on_time' or 'breached')
    │
    Power BI measure (SLA & Operations dashboard):
    [SLA On-Time Rate] =
        DIVIDE(
            COUNTROWS(FILTER(orders_fact, orders_fact[sla_status] = "on_time")),
            COUNTROWS(orders_fact)
        )

    Note: SLA status is only available at order level (orders_fact).
    It is not aggregated into store_sales_fact or other downstream facts.
    SLA analysis must be done from orders_fact directly.
```

---

### Delivery Days

```
Source: orders_stg.delivery_days
    │
    Passed through in: orders_fact
    Column: orders_fact.delivery_days (INTEGER)

    Power BI measures:
    [Avg Delivery Days] = AVERAGE(orders_fact[delivery_days])
    [Max Delivery Days] = MAX(orders_fact[delivery_days])

    Note: NULL for orders that were cancelled before dispatch or not yet delivered.
    Filter out NULLs in the BI layer when calculating averages.
```

---

### Units Sold (Product level)

```
Source: order_items_stg.quantity
    │
    Calculated in: product_sales_fact only
    Logic: SUM(oi.quantity) GROUP BY product_id, date_id
    Column: product_sales_fact.units_sold

    Note: units_sold includes quantities from cancelled orders.
    There is no units_sold_net column currently — if needed,
    add SUM(CASE WHEN cancelled_flag = 0 THEN quantity ELSE 0 END)
    to product_sales_fact.
```

---

### Average Order Value

```
Source: orders_fact.net_order_revenue
    │
    ├──► store_sales_fact
    │    Logic: AVG(orders_fact.net_order_revenue) GROUP BY store_id, full_date
    │    Column: store_sales_fact.avg_order_value
    │    Caveat: Cancelled orders contribute 0 to the numerator but are
    │            counted in the denominator — this suppresses the average.
    │
    └──► customer_revenue_fact
         Logic: AVG(orders_fact.net_order_revenue) GROUP BY customer_id, date_id
         Column: customer_revenue_fact.avg_order_value
         Same caveat applies.

    For a true average order value on completed orders only:
    Filter cancelled_flag = 0 in the BI layer, or
    add a completed_order_count column to the fact table.
```

---

## Source File to Dashboard Field — Full Trace Example

**Business question:** "What was Store 12's net revenue in January 2026?"

```
1. raw/orders/ in S3
   └─ file lands → Snowpipe auto-ingest

2. Bronze: raw_orders table (all VARCHAR)
   └─ Streams capture new rows

3. Tasks run → Silver: orders_stg
   Fields used: order_id, store_id, date_id, cancelled_flag

4. Tasks run → Silver: order_items_stg
   Fields used: order_id, line_revenue

5. Tasks run → Silver: dates_stg
   Fields used: date_id, date (full_date)

6. dbt: orders_fact
   Logic: JOIN orders_stg + order_items_stg + dates_stg
   Output: net_order_revenue per order

7. dbt: store_sales_fact
   Logic: SUM(net_order_revenue) WHERE store_id = 12 AND full_date BETWEEN ...
   Output: net_revenue per store per day

8. Power BI: Store Performance dashboard
   Measure: [Net Revenue] = SUM(store_sales_fact[net_revenue])
   Filter: store_id = 12, full_date in Jan 2026
   Visual: Bar chart — daily net revenue by store
```

---

## Known Lineage Gaps

| Gap | Detail | Impact |
|---|---|---|
| No dim tables documented | `dim_store`, `dim_product`, `dim_customer` are referenced in Power BI but not yet built as dbt models | Foreign keys in fact tables cannot be joined to dimension attributes without manually building these in dbt or Power BI |
| `product_sales_fact` reads staging directly | Unlike other downstream facts, this model bypasses `orders_fact` | A change to cancellation logic in `orders_fact` must also be manually applied to `product_sales_fact` |
| `units_sold` is not split by cancellation | Cancelled order units are included in `units_sold` | Overstates inventory demand if used for replenishment planning |
| SLA data not in downstream facts | `sla_status` and `delivery_days` only exist in `orders_fact` | Store-level or product-level SLA analysis requires joining back to `orders_fact` |

# Data Dictionary — Gold Layer

Auto Project | Automotive Retail Analytics Platform  
Layer: **Gold** (dbt Core) | Schema: `mart` in Snowflake  
Last updated: February 2026

---

## How to Read This Document

Each table entry contains:
- **Grain statement** — exactly one row represents what
- **Sources** — which Silver staging models feed this table
- **Column definitions** — type, nullable, and plain-English description
- **Business rules** — logic baked into the model that analysts must understand

Cancelled revenue is **never excluded** from any fact table — it is always tracked as a separate measure alongside net revenue. This is a deliberate Kimball modeling decision to prevent metric inflation while preserving full revenue visibility.

---

## Fact Tables

---

### `orders_fact`

**Grain:** One row per order.  
A single order can contain multiple line items (in `order_items_stg`). This table aggregates all line items to the order level. One row = one order, regardless of how many products were purchased.

**Sources:**
- `orders_stg` — order header (status, dates, store, customer, SLA)
- `order_items_stg` — line items (revenue per product per order)
- `dates_stg` — calendar attributes joined on `date_id`

**Why this is the central fact table:**  
`store_sales_fact` and `customer_revenue_fact` are both derived from `orders_fact` via `{{ ref('orders_fact') }}`. This means `orders_fact` is the single authoritative source for order-level revenue — downstream facts do not re-read staging models independently.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `order_id` | VARCHAR | NOT NULL | Primary key. Unique identifier for each order from the source transactional system. Deduplication is handled upstream in Silver. |
| `date_id` | VARCHAR | NOT NULL | Foreign key to `dates_stg`. Represents the date the order was placed. Used for joining to calendar dimensions. |
| `full_date` | DATE | NOT NULL | The calendar date of the order, resolved from `dates_stg`. Used directly in `store_sales_fact` for daily aggregation. |
| `store_id` | VARCHAR | NOT NULL | Foreign key to `dim_store`. The store that processed the order. |
| `customer_id` | VARCHAR | NOT NULL | Foreign key to `dim_customer`. The customer who placed the order. |
| `status` | VARCHAR | NOT NULL | Order status from the source system (e.g. `completed`, `pending`, `cancelled`). |
| `sla_status` | VARCHAR | NULLABLE | Whether the order met its delivery SLA. Expected values: `on_time`, `breached`. NULL if delivery data is unavailable. |
| `delivery_days` | INTEGER | NULLABLE | Number of days between order placement and delivery. NULL if the order has not yet been delivered or was cancelled before dispatch. |
| `cancelled_flag` | INTEGER | NOT NULL | `1` if the order was cancelled, `0` if not. Used in CASE expressions across all downstream facts to split net vs cancelled revenue. |
| `gross_order_value` | NUMERIC | NOT NULL | Sum of all `line_revenue` values for the order, regardless of cancellation status. Always populated. Represents the total order value before cancellation logic is applied. |
| `net_order_revenue` | NUMERIC | NOT NULL | `gross_order_value` when `cancelled_flag = 0`, otherwise `0`. Represents revenue that was actually realised. Use this for commercial reporting. |
| `cancelled_order_value` | NUMERIC | NOT NULL | `gross_order_value` when `cancelled_flag = 1`, otherwise `0`. Represents revenue that was lost to cancellation. Use this for cancellation rate and lost revenue reporting. |
| `loaded_at` | TIMESTAMP | NOT NULL | UTC timestamp of when this row was written to Gold by dbt. Used for pipeline monitoring and freshness checks — not a business date. |

**Business rules:**
- `gross_order_value = net_order_revenue + cancelled_order_value` always holds at the row level
- An order is never partially cancelled in this model — `cancelled_flag` is order-level, not line-item-level
- `net_order_revenue` and `cancelled_order_value` are mutually exclusive per row (one is always 0)
- Do not SUM `gross_order_value` and `net_order_revenue` together — this will double-count revenue

---

### `store_sales_fact`

**Grain:** One row per store per calendar day.  
Aggregates all orders processed by a store on a given day. If a store had no orders on a given day, no row exists for that store-day combination.

**Sources:**
- `orders_fact` — this model reads directly from `orders_fact`, not from staging

**Note:** Because this model is derived from `orders_fact`, any upstream fix to order-level revenue will automatically flow through to store-level aggregations on the next dbt run.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `store_id` | VARCHAR | NOT NULL | Foreign key to `dim_store`. The store for this daily summary row. |
| `full_date` | DATE | NOT NULL | The calendar date for this summary row. Sourced from `orders_fact.full_date`. |
| `order_count` | INTEGER | NOT NULL | Number of distinct orders placed at this store on this date. |
| `net_revenue` | NUMERIC | NOT NULL | Sum of `net_order_revenue` for all non-cancelled orders at this store on this date. |
| `cancelled_revenue` | NUMERIC | NOT NULL | Sum of `cancelled_order_value` for all cancelled orders at this store on this date. |
| `gross_revenue` | NUMERIC | NOT NULL | Sum of `gross_order_value` for all orders at this store on this date, regardless of status. |
| `avg_order_value` | NUMERIC | NOT NULL | Average `net_order_revenue` across all orders at this store on this date. Cancelled orders contribute `0` to this average, which suppresses the mean — use with awareness. |
| `cancelled_orders` | INTEGER | NOT NULL | Count of orders at this store on this date where `cancelled_flag = 1`. |
| `loaded_at` | TIMESTAMP | NOT NULL | UTC timestamp of when this row was written by dbt. |

**Business rules:**
- `gross_revenue = net_revenue + cancelled_revenue` holds at every row
- `avg_order_value` includes cancelled orders in the denominator (they contribute `0` to the numerator). For avg revenue per completed order, filter `cancelled_flag = 0` in the BI layer
- This table does not contain a date foreign key — it uses `full_date` (a DATE column) directly. Join to a calendar dimension in Power BI using this column

---

### `product_sales_fact`

**Grain:** One row per product per calendar day.  
Aggregates all line items for a product across all orders placed on a given day.

**Sources:**
- `order_items_stg` — line-item level revenue and quantity
- `orders_stg` — joined to get `cancelled_flag` and `date_id` at order level

**Note:** This model reads from staging directly (not from `orders_fact`), because it needs line-item granularity (quantity per product) that is lost once orders are aggregated.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `product_id` | VARCHAR | NOT NULL | Foreign key to `dim_product`. The product for this daily summary. |
| `date_id` | VARCHAR | NOT NULL | Foreign key to `dates_stg`. The date on which these line items were ordered. |
| `units_sold` | INTEGER | NOT NULL | Total quantity of this product ordered on this date, regardless of cancellation status. |
| `net_revenue` | NUMERIC | NOT NULL | Sum of `line_revenue` for line items where the parent order was not cancelled (`cancelled_flag = 0`). |
| `gross_revenue` | NUMERIC | NOT NULL | Sum of all `line_revenue` for this product on this date, regardless of cancellation. |
| `cancelled_revenue` | NUMERIC | NOT NULL | Sum of `line_revenue` for line items where the parent order was cancelled (`cancelled_flag = 1`). |
| `order_count` | INTEGER | NOT NULL | Count of distinct orders that included this product on this date. A single order can contain multiple units of the same product — this counts the order, not the quantity. |
| `loaded_at` | TIMESTAMP | NOT NULL | UTC timestamp of when this row was written by dbt. |

**Business rules:**
- `gross_revenue = net_revenue + cancelled_revenue` holds at every row
- `units_sold` counts all units including those in cancelled orders. For units sold on completed orders only, this requires a separate column or BI-layer filter — it is not currently split in this model
- Cancellation is at the **order level** in the source data — if an order is cancelled, all its line items are treated as cancelled. There is no partial line-item cancellation

---

### `customer_revenue_fact`

**Grain:** One row per customer per calendar day.  
Aggregates all order activity for a customer on a given day. Derived from `orders_fact`.

**Sources:**
- `orders_fact` — this model reads directly from `orders_fact`

| Column | Type | Nullable | Description |
|---|---|---|---|
| `customer_id` | VARCHAR | NOT NULL | Foreign key to `dim_customer`. The customer for this daily summary. |
| `date_id` | VARCHAR | NOT NULL | Foreign key to `dates_stg`. The date for this summary row. |
| `order_count` | INTEGER | NOT NULL | Number of distinct orders placed by this customer on this date. |
| `net_revenue` | NUMERIC | NOT NULL | Sum of `net_order_revenue` across all orders by this customer on this date. |
| `avg_order_value` | NUMERIC | NOT NULL | Average `net_order_revenue` per order for this customer on this date. Cancelled orders contribute `0` — same suppression caveat as `store_sales_fact`. |
| `cancelled_revenue` | NUMERIC | NOT NULL | Sum of `cancelled_order_value` across all cancelled orders by this customer on this date. |
| `cancelled_orders` | INTEGER | NOT NULL | Count of orders placed by this customer on this date that were cancelled. |
| `loaded_at` | TIMESTAMP | NOT NULL | UTC timestamp of when this row was written by dbt. |

**Business rules:**
- This is a daily grain — it does not represent lifetime customer value. For customer LTV, aggregate across all dates in the BI layer using `SUM(net_revenue)` over all `date_id` values per `customer_id`
- `cancelled_orders` divided by `order_count` gives the customer's daily cancellation rate
- A customer with only cancelled orders on a given day will have `net_revenue = 0` and `cancelled_revenue > 0` — they still have a row in this table

---

## Staging Models (Silver → dbt input)

These are not Gold models but are referenced by Gold facts. They are the cleaned outputs from Snowflake Tasks, read by dbt as source models.

| Staging Model | Grain | Key Columns |
|---|---|---|
| `orders_stg` | 1 row per order | `order_id`, `date_id`, `store_id`, `customer_id`, `status`, `sla_status`, `delivery_days`, `cancelled_flag` |
| `order_items_stg` | 1 row per order line item | `order_id`, `product_id`, `quantity`, `line_revenue` |
| `dates_stg` | 1 row per calendar date | `date_id`, `date`, `day_of_week`, `month`, `quarter`, `year` |

---

## Revenue Metric Definitions

These definitions apply consistently across all Gold models:

| Metric | Definition |
|---|---|
| **Gross Revenue** | Total order value before cancellation logic. Always populated. |
| **Net Revenue** | Revenue from completed (non-cancelled) orders only. Use for commercial P&L reporting. |
| **Cancelled Revenue** | Revenue from cancelled orders. Use for cancellation rate and lost revenue analysis. |
| **Gross = Net + Cancelled** | This identity holds at every grain level — order, store-day, product-day, customer-day. |

{% snapshot products_snapshot %}

{{
    config(
        target_database = 'AUTO_DB',
        target_schema   = 'snapshots',
        unique_key      = 'product_id',
        strategy        = 'timestamp',
        updated_at      = 'processed_at',
    )
}}

/*
    SCD Type 2 snapshot for products.

    Strategy: timestamp
    Reason: products_stg carries processed_at from the source system.
    dbt compares processed_at on each run — if it has advanced for a
    product_id, a new historical row is opened and the previous row
    is closed (dbt_valid_to is set).

    Tracked attributes (all non-key columns are tracked automatically
    with timestamp strategy — dbt opens a new row if processed_at
    advances, regardless of which column changed):
    - category:    product recategorisation is common in automotive retail
    - brand:       brand reassignment or rebranding
    - margin:      pricing and margin changes — critical for revenue analysis
    - seasonality: seasonal classification changes affect demand forecasting

    Why this matters for analytics:
    Without SCD Type 2, a margin change on a product retroactively
    changes historical revenue calculations. With this snapshot, each
    historical order can be joined to the product's margin at the time
    of the order — not today's margin.
*/

select
    product_id,
    product_name,
    brand,
    category,
    margin,
    seasonality,
    processed_at

from {{ source('auto_stg', 'stg_products') }}

{% endsnapshot %}
{% snapshot customers_snapshot %}

{{
    config(
        target_database = 'AUTO_DB',
        target_schema   = 'snapshots',
        unique_key      = 'customer_id',
        strategy        = 'timestamp',
        updated_at      = 'processed_at',
    )
}}

/*
    SCD Type 2 snapshot for customers.

    Strategy: timestamp
    Reason: customers_stg carries processed_at from the source system.
    Same logic as products_snapshot — dbt opens a new historical row
    when processed_at advances for a customer_id.

    Tracked attributes:
    - derived_region: customer region is derived (not directly from source)
                      and can change as the business updates segmentation logic.
                      This is the most likely change — track it carefully.
    - city:           customers move — city changes affect regional analysis
    - email:          customers update contact details

    Not tracked:
    - first_name / last_name: name corrections are admin fixes, not
                              meaningful business changes. Tracking them
                              would generate noise SCD rows.

    Why this matters for analytics:
    Customer churn and LTV calculations depend on which region a customer
    belonged to at the time of each order. Without SCD Type 2, a customer
    who moved region would have all historical orders attributed to their
    current region — misrepresenting regional performance.
*/

select
    customer_id,
    first_name,
    last_name,
    email,
    city,
    derived_region,
    processed_at

from {{ source('auto_stg', 'stg_customers') }}

{% endsnapshot %}
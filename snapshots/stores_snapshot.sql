{% snapshot stores_snapshot %}

{{
    config(
        target_database = 'AUTO_DB',
        target_schema   = 'snapshots',
        unique_key      = 'store_id',
        strategy        = 'check',
        check_cols      = ['store_name', 'region', 'country'],
    )
}}

/*
    SCD Type 2 snapshot for stores.

    Strategy: check
    Reason: stores_stg generates loaded_at via current_timestamp at query
    time — it is not a reliable source-system updated_at timestamp.
    The check strategy compares column values directly and opens a new
    historical row whenever store_name, region, or country changes.

    Tracked columns and why:
    - region:     stores get reassigned to regions (most common change)
    - country:    unlikely but tracked for completeness
    - store_name: store rebranding or renaming

    Not tracked:
    - opened_date: immutable — a store's opening date never changes
    - loaded_at:   pipeline metadata, not a business attribute
*/

select
    store_id,
    store_name,
    region,
    country,
    opened_date,
    current_timestamp as loaded_at

from {{ source('auto_stg', 'stores') }}

{% endsnapshot %}
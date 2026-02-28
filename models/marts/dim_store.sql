/*
    dim_store — Store dimension with SCD Type 2 history

    Source: stores_snapshot (AUTO_DB.snapshots.stores_snapshot)

    This model reads from the snapshot rather than stores_stg directly.
    Each row represents a store's attributes during a specific time period.

    SCD Type 2 columns added by dbt snapshot:
    - dbt_scd_id:    surrogate key unique to each historical record
    - dbt_valid_from: when this version of the store record became active
    - dbt_valid_to:   when this version was superseded (NULL = current record)
    - dbt_updated_at: when dbt last touched this record

    How to use in Power BI / analysis:
    - Current records only:   WHERE dbt_valid_to IS NULL
    - Point-in-time analysis: WHERE order_date BETWEEN dbt_valid_from
                              AND COALESCE(dbt_valid_to, CURRENT_DATE)
*/

select
    -- Surrogate key for this specific historical version
    dbt_scd_id                          as store_version_key,

    -- Natural business key
    store_id,

    -- Store attributes (values at this point in time)
    store_name,
    region,
    country,
    opened_date,

    -- SCD Type 2 validity window
    dbt_valid_from                      as valid_from,
    dbt_valid_to                        as valid_to,

    -- Convenience flag for current record filter
    case
        when dbt_valid_to is null then true
        else false
    end                                 as is_current,

    -- Pipeline metadata
    dbt_updated_at                      as snapshot_updated_at

from {{ ref('stores_snapshot') }}

/*
    dim_product — Product dimension with SCD Type 2 history

    Source: products_snapshot (AUTO_DB.snapshots.products_snapshot)

    Each row represents a product's attributes during a specific period.
    When margin, category, brand, or seasonality changes, a new row is
    opened and the previous row's dbt_valid_to is set.

    Critical use case — margin-accurate revenue analysis:
    JOIN fact tables to dim_product on product_id AND:
        order_date BETWEEN valid_from AND COALESCE(valid_to, CURRENT_DATE)
    This returns the margin that was active at the time of the order,
    not today's margin — essential for accurate historical P&L.
*/

select
    -- Surrogate key for this specific historical version
    dbt_scd_id                          as product_version_key,

    -- Natural business key
    product_id,

    -- Product attributes (values at this point in time)
    product_name,
    brand,
    category,
    margin,
    seasonality,

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

from {{ ref('products_snapshot') }}

/*
    dim_customer — Customer dimension with SCD Type 2 history

    Source: customers_snapshot (AUTO_DB.snapshots.customers_snapshot)

    Each row represents a customer's attributes during a specific period.
    When derived_region or city changes, a new historical row is opened.

    Critical use case — region-accurate revenue analysis:
    Without this snapshot, a customer who moved from London to Manchester
    would have ALL their historical orders attributed to Manchester.
    With this snapshot, orders are attributed to the region the customer
    belonged to at the time of purchase.

    JOIN pattern for point-in-time accuracy:
        JOIN dim_customer dc
          ON fact.customer_id = dc.customer_id
         AND fact.full_date BETWEEN dc.valid_from
             AND COALESCE(dc.valid_to, CURRENT_DATE)
*/

select
    -- Surrogate key for this specific historical version
    dbt_scd_id                          as customer_version_key,

    -- Natural business key
    customer_id,

    -- Customer attributes (values at this point in time)
    first_name,
    last_name,
    first_name || ' ' || last_name      as full_name,
    email,
    city,
    derived_region,

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

from {{ ref('customers_snapshot') }}

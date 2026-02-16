select
  customer_id,
  first_name,
  last_name,
  email,
  city,
  derived_region,
  processed_at
from {{ source('auto_stg', 'stg_customers') }}


select
  customer_id,
  first_name || ' ' || last_name as customer_name,
  email,
  city,
  derived_region
from {{ ref('customers_stg') }}

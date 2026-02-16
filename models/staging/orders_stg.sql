select
  order_id,
  customer_id,
  store_id,
  to_varchar(to_date(order_date), 'YYYYMMDD') as date_id,
  status,
  region,
  delivery_days,
  sla_status,
  cancelled_flag,
  processed_at
from {{ source('auto_stg', 'stg_orders') }}


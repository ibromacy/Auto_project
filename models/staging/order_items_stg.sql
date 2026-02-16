select
  order_item_id,
  order_id,
  product_id,
  quantity,
  unit_price,
  quantity * unit_price as line_revenue
from {{ source('auto_stg', 'stg_order_items') }}

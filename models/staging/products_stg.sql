select
  product_id,
  product_name,
  brand,
  category,
  margin,
  seasonality,
  processed_at
from {{ source('auto_stg', 'stg_products') }}


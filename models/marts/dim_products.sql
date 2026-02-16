select
  product_id,
  product_name,
  brand,
  category,
  margin,
  seasonality
from {{ ref('products_stg') }}

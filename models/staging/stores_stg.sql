select
  store_id,
  store_name,
  region,
  country,
  opened_date,
  current_timestamp as loaded_at
from {{ source('auto_stg', 'stores') }}

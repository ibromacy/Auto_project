select
  employee_id,
  store_id,
  role,
  salary,
  effective_from,
  effective_to,
  is_current
from {{ source('auto_stg', 'stg_employees') }}


select
  employee_id,
  store_id,
  role,
  salary
from {{ ref('employees_stg') }}
where is_current = true

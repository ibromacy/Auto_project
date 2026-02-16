select 
date_id,
  date,
  year,
  quarter,
  month,
  month_name,
  week,
  day,
  day_name,
  is_winter,
  is_summer
  from {{ source('auto_stg', 'dates') }}
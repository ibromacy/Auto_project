select
  date_id,
  date           as full_date,
  year,
  quarter,
  month,
  month_name,
  week           as week_of_year,
  day,
  day_name,
  is_winter,
  is_summer,

  case
    when is_winter then 'Winter'
    when is_summer then 'Summer'
    else 'Other'
  end as season,

  current_timestamp as loaded_at

from {{ ref('dates_stg') }}


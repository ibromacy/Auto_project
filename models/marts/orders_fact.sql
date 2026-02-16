select
  o.order_id,
  o.date_id,
  d.date as full_date,
  o.store_id,
  o.customer_id,

  o.status,
  o.sla_status,
  o.delivery_days,
  o.cancelled_flag,

  -- Always calculated
  sum(oi.line_revenue) as gross_order_value,

  -- Business revenue (Kimball-safe)
  case 
    when o.cancelled_flag = 0 then sum(oi.line_revenue)
    else 0
  end as net_order_revenue,

  -- Explicit lost revenue
  case 
    when o.cancelled_flag = 1 then sum(oi.line_revenue)
    else 0
  end as cancelled_order_value,

  current_timestamp as loaded_at

from {{ ref('orders_stg') }} o
join {{ ref('order_items_stg') }} oi
  on o.order_id = oi.order_id
join {{ ref('dates_stg') }} d
  on o.date_id = d.date_id

group by
  o.order_id,
  o.date_id,
  d.date,
  o.store_id,
  o.customer_id,
  o.status,
  o.sla_status,
  o.delivery_days,
  o.cancelled_flag




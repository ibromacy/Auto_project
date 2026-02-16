select
  store_id,
  full_date,

  count(distinct order_id) as order_count,

  sum(net_order_revenue) as net_revenue,
  sum(cancelled_order_value) as cancelled_revenue,
  sum(gross_order_value) as gross_revenue,

  avg(net_order_revenue) as avg_order_value,

  sum(case when cancelled_flag = 1 then 1 else 0 end) as cancelled_orders,

  current_timestamp as loaded_at

from {{ ref('orders_fact') }}

group by store_id, full_date


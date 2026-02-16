select
  customer_id,date_id,

  count(distinct order_id) as order_count,

  sum(net_order_revenue) as net_revenue,

  avg(net_order_revenue) as avg_order_value,

  sum(cancelled_order_value) as cancelled_revenue,

  sum(case when cancelled_flag = 1 then 1 else 0 end) as cancelled_orders,

  current_timestamp as loaded_at

from {{ ref('orders_fact') }} 

group by customer_id,date_id


select
  oi.product_id,
  o.date_id,

  sum(oi.quantity) as units_sold,

  sum(case when o.cancelled_flag = 0
           then oi.line_revenue
           else 0 end) as net_revenue,

  sum(oi.line_revenue) as gross_revenue,

  sum(case when o.cancelled_flag = 1
           then oi.line_revenue
           else 0 end) as cancelled_revenue,

  count(distinct oi.order_id) as order_count,

  current_timestamp as loaded_at

from {{ ref('order_items_stg') }} oi
join {{ ref('orders_stg') }} o
  on oi.order_id = o.order_id

group by oi.product_id,o.date_id




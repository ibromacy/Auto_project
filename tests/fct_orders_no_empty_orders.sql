select *
from {{ ref('orders_fact') }}
where gross_order_value = 0
and net_order_revenue=0

select *
from {{ ref('orders_fact') }}
where gross_order_value < 0

select *
from {{ ref('store_sales_fact') }}
where  net_revenue< 0

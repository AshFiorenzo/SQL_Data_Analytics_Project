--  CHANGES OVER TIME ANALYSIS 
-- changes over year 
select 
    year(order_date) as year,
    sum(sales_amount) as total_sales,
    count(distinct customer_key) as total_customers,
from 
    gold.fact_sales
where order_date IS NOT NULL
group by year(order_date)
order by year(order_date);
-- changes over month by month basic
select 
    month(order_date) as month,
    sum(sales_amount) as total_sales,
    count(distinct customer_key) as total_customers,
from 
    gold.fact_sales
where order_date IS NOT NULL
group by month(order_date)
order by month(order_date);
-- both year and month
select 
    datetrunc('month', order_date) as order_date,
    sum(sales_amount) as total_sales,
    count(distinct customer_key) as total_customers,
from 
    gold.fact_sales
where order_date IS NOT NULL
group by datetrunc('month', order_date)
order by datetrunc('month', order_date);
-- strftime function
select 
    STRFTIME(order_date,'%Y-%b') as order_date,
    sum(sales_amount) as total_sales,
    count(distinct customer_key) as total_customers,
from 
    gold.fact_sales
where order_date IS NOT NULL
group by STRFTIME(order_date,'%Y-%b')
order by STRFTIME(order_date,'%Y-%b');
--=======================
--  CUMULATIVE ANALYSIS 
-- Aggregate the data progressively over time. Helps to understand whether our business is growing or declining.
--========================
-- Calculate the total sales per month
select 
    datetrunc('month', order_date) as month, 
    sum(sales_amount) as total_sales
from gold.fact_sales
where order_date is not null 
group by  datetrunc('month', order_date)
order by  datetrunc('month', order_date);
-- and the running total of sales over time 
select 
    order_month,
    total_sales,
    sum(total_sales) over (partition by order_month order by order_month) as running_total_sales,
    avg(total_sales) over (partition by order_month order by order_month) as moving_average_sales
from (
    select 
    datetrunc('month', order_date) as order_month, 
    sum(sales_amount) as total_sales,
    avg(sales_amount) as avg_sales
    from gold.fact_sales
    where order_date is not null  
    group by  datetrunc('month', order_date)
    order by datetrunc('month', order_date)
);
--======================
-- PEFROMANCE ANALYSIS
-- Comparing the current value to a target value. This helps measure success and compare performance.
--=======================
-- Analyze the yearly performance of products by comparing each product's sales to both
-- its average sales performance and the previous year's sales.
WITH yearly_product_sales as (
select
    year(fs.order_date) as order_year,
    dp.product_name,
    sum(fs.sales_amount) as total_sales
from 
    gold.fact_sales as fs left join gold.dim_products as dp on fs.product_key = dp.product_key
where order_year is not null 
group by dp.product_name, year(fs.order_date)
order by order_year
)
select 
    order_year,
    product_name,
    total_sales,
    avg(total_sales) over (partition by product_name)::INT as average_sales,
    total_sales - average_sales as diff_with_average,
    case 
        when  total_sales - average_sales > 0 THEN 'Above average'
        when  total_sales - average_sales < 0 THEN 'Below average'
        ELSE 'Average'
    END as above_or_below,
    LAG(total_sales) over (partition by product_name order by order_year) as pervious_year_sales,
    case   
        when total_sales - LAG(total_sales) over (partition by product_name order by order_year) > 0 THEN 'Increase'
        when total_sales - LAG(total_sales) over (partition by product_name order by order_year) < 0 THEN 'Decrease'
        ELSE 'no change'
    END as compared_to_last_year
from yearly_product_sales
order by product_name,order_year;

--=========================
-- Part to Whole Analysis 
--=========================
-- Which categories contribute the most to overall sales?
with category_sales as (
    select  
        dp.category,
        sum(fs.sales_amount) as total_sales,

    from 
        gold.fact_sales as fs left join gold.dim_products as dp on fs.product_key = dp.product_key
    group by dp.category
)
select 
    category,
    total_sales,
    sum(total_sales) over () as overall_sales,
    concat(round((total_sales::double / sum(total_sales) over ())*100, 2),'%')as percent_of_total
from 
    category_sales
order by total_sales desc;

--======================
-- Data segmentation - [measure] by [measure]
--======================
-- Segment products into cost ranges and count how many products fall into each segment.
WITH product_segments as (
    select 
        product_key,
        product_name,
        product_cost,
        CASE 
            WHEN product_cost <100 THEN 'Below 100'
            WHEN product_cost BETWEEN 100 AND 500 THEN '100-500'
            WHEN product_cost BETWEEN 500 AND 1000 THEN '500-1000'
            ELSE 'above 1000'
        END as cost_range
    from
        gold.dim_products
)
select 
    cost_range,
    count(product_key) as total_products
from 
    product_segments
group by cost_range;

-- Group customers into three segments based on their spending behavior:
-- VIP: at least 12 months of history and spending more than €5,000.
-- Regular: at least 12 months of history but spending €5,000 or less.
-- New: lifespan less than 12 months.
-- And find the total number of customers by each group.
WITH customer_spending_lifespan AS (
    select 
        dc.customer_key,
        sum(fs.sales_amount) as total_spending,
        min(order_date) as first_order,
        max(order_date) as last_order,
        date_diff('month',first_order, last_order) as life_span
    from 
        gold.fact_sales as fs left join gold.dim_customers as dc on fs.customer_key = dc.customer_key
    group by dc.customer_key
)
select 
    CASE 
        WHEN life_span > 12 and total_spending > 5000 THEN 'VIP'
        WHEN life_span >= 12 and total_spending <= 5000 THEN 'Regular'
        ELSE 'NEW'
    END as customer_segment,
    count(customer_key) as total_customers
from 
    customer_spending_lifespan
group by customer_segment;

--=====================
-- Build report (as view)
--=====================
-- purpose:
-- - This report consolidates key customer metrics and behaviors
-- Highlights:
-- 1. Gathers essential fields such as names, ages, and transaction details.
-- 2. Segments customers into categories (VIP, Regular, New) and age groups.
-- 3. Aggregates customer-level metrics:
-- total orders
-- total sales
-- total quantity purchased
-- total products
-- lifespan (in months)
-- 4. Calculates valuable KPIs:
-- recency (months since last order)
-- average order value
-- average monthly spend
CREATE VIEW gold.report_customers as 
WITH base_query as (
select 
    fs.order_number,
    fs.product_key,
    fs.order_date,
    fs.sales_amount,
    fs.quantity,
    c.customer_key,
    c.customer_number,
    concat(c.first_name,' ',c.last_name) as full_name,
    date_diff('year',c.birthday,CURRENT_DATE) as age 
from 
    gold.fact_sales as fs left join gold.dim_customers as c on fs.customer_key = c.customer_key
where 
    fs.order_date is not null 
),
customer_aggregation as ( 
select 
    customer_key,
    customer_number,
    full_name,
    age,
    min(order_date) as first_order_date,
    max(order_date) as last_order_date,
    count(distinct order_number) as total_order,
    sum(sales_amount) as total_sales,
    sum(quantity) as total_quantity,
    count(distinct product_key) as total_products,
    date_diff('month',min(order_date), max(order_date)) as life_span
from 
    base_query
group by 
    customer_key,
    customer_number,
    full_name,
    age
)
select 
    customer_key,
    customer_number,
    full_name,
    age,
    CASE 
        WHEN age < 20  THEN 'Under 20'
        WHEN age between 20 and 29 THEN '20-29'
        WHEN age between 30 and 39 THEN '30-39'
        WHEN age between 40 and 49 THEN '40-49'
        ELSE 'above 50'
    END as age_group,
    life_span,
    CASE 
        WHEN life_span > 12 and total_sales > 5000 THEN 'VIP'
        WHEN life_span >= 12 and total_sales <= 5000 THEN 'Regular'
        ELSE 'NEW'
    END as customer_segment,
    total_order,
    total_sales,
    total_quantity,
    total_products,
    date_diff('month', last_order_date, CURRENT_DATE) as month_since_last_order,
    CASE 
        WHEN total_order = 0 THEN 0 
        ELSE total_sales / total_order 
    END as average_order_value,
    CASE 
        WHEN life_span = 0 THEN total_sales
        ELSE total_sales / life_span
    END as average_monthly_spend
from 
    customer_aggregation;

select * from gold.report_customers;
--========
-- Product Report
-- ========
-- Purpose:
-- - This report consolidates key product metrics and behaviors.
-- Highlights:
-- 1. Gathers essential fields such as product name, category, subcategory, and cost.
-- 2. Segments products by revenue to identify High-Performers, Mid-Range, or Low-Performers.
-- 3. Aggregates product-level metrics:
-- - total orders
-- - total sales
-- - total quantity sold
-- - total customers (unique)
-- - lifespan (in months)
-- 4. Calculates valuable KPIs:
-- - recency (months since last sale)
-- - average order revenue (AOR)
-- - average monthly revenue

CREATE VIEW gold.report_products as 
WITH base_query as (
select 
    fs.order_number,
    fs.order_date,
    fs.customer_key,
    fs.sales_amount,
    fs.quantity,
    p.product_key,
    p.product_name,
    p.category,
    p.sub_category,
    p.product_cost
from 
    gold.fact_sales as fs left join gold.dim_products as p on fs.product_key = p.product_key
where 
    fs.order_date is not null 
),
product_aggregation as ( 
select 
    product_key,
    product_name,
    category,
    sub_category,
    product_cost, 
    min(order_date) as first_sale_date,
    max(order_date) as last_sale_date,
    date_diff('month',min(order_date), max(order_date)) as life_span,
    count(distinct order_number) as total_order,
    sum(sales_amount) as total_sales,
    sum(quantity) as total_quantity,
    count(distinct customer_key) as total_customers,
    round(avg(sales_amount/nullif(quantity,0)),2) as average_sale_price
from 
    base_query
group by 
    product_key,
    product_name,
    category,
    sub_category,
    product_cost
)
select 
    product_key,
    product_name,
    category,
    sub_category,
    product_cost, 
    last_sale_date,
    date_diff('month',last_sale_date, CURRENT_DATE) as recency_in_months,
    CASE 
        WHEN total_sales > 50000  THEN 'Higer Performer'
        WHEN total_sales >= 10000  THEN 'Mid range'
        ELSE 'Low Performer'
    END as product_segment,
    life_span,
    total_order,
    total_sales,
    total_quantity,
    total_customers,
    average_sale_price,
    CASE 
        WHEN total_order = 0 THEN 0 
        ELSE total_sales / total_order 
    END as average_order_revenue,
    CASE 
        WHEN life_span = 0 THEN total_sales
        ELSE total_sales / life_span
    END as average_monthly_revenue
from 
    product_aggregation;

select * from gold.report_products;
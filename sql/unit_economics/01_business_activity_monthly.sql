/*
Purpose:
    Create monthly business-activity measures by application and environment.

Grain:
    One row per activity month, application, department, environment,
    cost center and owner.

Source:
    retail_finops_raw.raw_business_activity
    retail_finops_control.business_dimension_reference

Key controls:
    - Every activity workload maps to one business dimension.
    - Transactions, requests and revenue are additive.
    - Active customers use average daily active customers.
    - Monthly lineage retains workload and driver information.
    - The source period remains visible and reproducible.

Owner:
    FinOps Analytics.

Refresh:
    After the deterministic business-activity CSV is loaded.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_business_activity_monthly`

PARTITION BY activity_month

CLUSTER BY
    application_name,
    department_name,
    environment_name,
    cost_center

AS

WITH enriched_activity AS (
    SELECT
        activity.activity_date,
        activity.workload_id,

        dimension.application_name,
        dimension.department_name,

        dimension.environment
            AS environment_name,

        dimension.cost_center,

        dimension.owner_team
            AS owner_name,

        dimension.business_driver,

        activity.demand_index,
        activity.traffic,
        activity.transactions,
        activity.queries,
        activity.support_requests,
        activity.ai_requests,
        activity.api_requests,
        activity.active_customers,
        activity.revenue

    FROM
        `__PROJECT_ID__.retail_finops_raw.raw_business_activity`
            AS activity

    INNER JOIN
        `__PROJECT_ID__.retail_finops_control.business_dimension_reference`
            AS dimension

        ON dimension.workload_id
            = activity.workload_id

       AND dimension.environment
            = activity.environment
),

daily_application_activity AS (
    SELECT
        activity_date,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        SUM(demand_index)
            AS daily_demand_index,

        SUM(traffic)
            AS daily_traffic,

        SUM(transactions)
            AS daily_transactions,

        SUM(queries)
            AS daily_queries,

        SUM(support_requests)
            AS daily_support_requests,

        SUM(ai_requests)
            AS daily_ai_requests,

        SUM(api_requests)
            AS daily_api_requests,

        SUM(active_customers)
            AS daily_active_customers,

        SUM(revenue)
            AS daily_revenue

    FROM enriched_activity

    GROUP BY
        activity_date,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name
),

monthly_activity AS (
    SELECT
        DATE_TRUNC(
            activity_date,
            MONTH
        ) AS activity_month,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        COUNT(DISTINCT activity_date)
            AS activity_day_count,

        CAST(
            SUM(daily_demand_index)
            AS NUMERIC
        ) AS total_demand_index,

        CAST(
            SUM(daily_traffic)
            AS NUMERIC
        ) AS traffic,

        CAST(
            SUM(daily_transactions)
            AS NUMERIC
        ) AS transactions,

        CAST(
            SUM(daily_queries)
            AS NUMERIC
        ) AS queries,

        CAST(
            SUM(daily_support_requests)
            AS NUMERIC
        ) AS support_requests,

        CAST(
            SUM(daily_ai_requests)
            AS NUMERIC
        ) AS ai_requests,

        CAST(
            SUM(daily_api_requests)
            AS NUMERIC
        ) AS api_requests,

        CAST(
            AVG(daily_active_customers)
            AS NUMERIC
        ) AS average_daily_active_customers,

        CAST(
            MAX(daily_active_customers)
            AS NUMERIC
        ) AS peak_daily_active_customers,

        CAST(
            SUM(daily_revenue)
            AS NUMERIC
        ) AS revenue

    FROM daily_application_activity

    GROUP BY
        DATE_TRUNC(
            activity_date,
            MONTH
        ),
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name
),

monthly_lineage AS (
    SELECT
        DATE_TRUNC(
            activity_date,
            MONTH
        ) AS activity_month,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        STRING_AGG(
            DISTINCT workload_id,
            ', '
            ORDER BY workload_id
        ) AS workload_ids,

        STRING_AGG(
            DISTINCT business_driver,
            ', '
            ORDER BY business_driver
        ) AS business_drivers,

        COUNT(DISTINCT workload_id)
            AS workload_count

    FROM enriched_activity

    GROUP BY
        DATE_TRUNC(
            activity_date,
            MONTH
        ),
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name
),

final_monthly_activity AS (
    SELECT
        activity.activity_month,

        activity.application_name,
        activity.department_name,
        activity.environment_name,
        activity.cost_center,
        activity.owner_name,

        lineage.workload_ids,
        lineage.business_drivers,
        lineage.workload_count,

        activity.activity_day_count,

        activity.total_demand_index,
        activity.traffic,
        activity.transactions,
        activity.queries,
        activity.support_requests,
        activity.ai_requests,
        activity.api_requests,

        activity.average_daily_active_customers,
        activity.peak_daily_active_customers,

        activity.revenue

    FROM monthly_activity AS activity

    INNER JOIN monthly_lineage AS lineage

        ON lineage.activity_month
            = activity.activity_month

       AND lineage.application_name
            = activity.application_name

       AND lineage.department_name
            = activity.department_name

       AND lineage.environment_name
            = activity.environment_name

       AND lineage.cost_center
            = activity.cost_center

       AND lineage.owner_name
            = activity.owner_name
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                CAST(activity_month AS STRING),
                '|',
                application_name,
                '|',
                department_name,
                '|',
                environment_name,
                '|',
                cost_center,
                '|',
                owner_name
            )
        )
    ) AS activity_month_id,

    activity_month,

    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,

    workload_ids,
    business_drivers,
    workload_count,

    activity_day_count,

    total_demand_index,
    traffic,
    transactions,
    queries,
    support_requests,
    ai_requests,
    api_requests,

    average_daily_active_customers,
    peak_daily_active_customers,

    revenue,

    TRUE
        AS is_synthetic_activity,

    'data/business_activity/business_activity.csv'
        AS activity_source,

    'SEEDED_DETERMINISTIC_GENERATOR'
        AS generation_method,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM final_monthly_activity;

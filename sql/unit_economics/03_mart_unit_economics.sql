/*
Purpose:
    Calculate application-level cloud unit economics.

Grain:
    One row per month, provider and application.

Source:
    mart_unit_economics_cost_base
    mart_business_activity_monthly

Key controls:
    - Business activity comes from production workloads.
    - Application cost contains production and non-production infrastructure.
    - AWS and GCP remain separately visible.
    - ALL_CLOUD is calculated from provider cost before joining activity.
    - Unallocated cost remains visible but does not receive fabricated units.
    - Every metric is reproducible from explicit numerator and denominator.

Owner:
    FinOps Analytics.

Refresh:
    After monthly business activity and cost base refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_unit_economics`

PARTITION BY unit_economics_month

CLUSTER BY
    provider_name,
    application_name,
    department_name,
    cost_center

AS

WITH production_activity AS (
    SELECT
        activity_month,

        application_name,
        department_name,
        cost_center,
        owner_name,

        SUM(activity_day_count)
            AS activity_day_count,

        SUM(traffic)
            AS traffic,

        SUM(transactions)
            AS transactions,

        SUM(queries)
            AS queries,

        SUM(support_requests)
            AS support_requests,

        SUM(ai_requests)
            AS ai_requests,

        SUM(api_requests)
            AS api_requests,

        SUM(
            average_daily_active_customers
        ) AS average_daily_active_customers,

        SUM(
            peak_daily_active_customers
        ) AS peak_daily_active_customers,

        SUM(revenue)
            AS revenue,

        LOGICAL_AND(
            is_synthetic_activity
        ) AS is_synthetic_activity

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_business_activity_monthly`

    WHERE LOWER(environment_name) = 'prod'

    GROUP BY
        activity_month,
        application_name,
        department_name,
        cost_center,
        owner_name
),

provider_cost AS (
    SELECT
        billing_month,

        provider_name,
        application_name,
        department_name,
        cost_center,
        owner_name,
        billing_currency,

        allocation_row_count,
        source_record_count,

        total_allocated_cost,
        production_cost,
        nonproduction_cost,
        direct_cost,
        shared_allocated_cost,
        unallocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics_cost_base`
),

all_cloud_cost AS (
    SELECT
        billing_month,

        'ALL_CLOUD'
            AS provider_name,

        application_name,
        department_name,
        cost_center,
        owner_name,
        billing_currency,

        SUM(allocation_row_count)
            AS allocation_row_count,

        SUM(source_record_count)
            AS source_record_count,

        CAST(
            SUM(total_allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost,

        CAST(
            SUM(production_cost)
            AS NUMERIC
        ) AS production_cost,

        CAST(
            SUM(nonproduction_cost)
            AS NUMERIC
        ) AS nonproduction_cost,

        CAST(
            SUM(direct_cost)
            AS NUMERIC
        ) AS direct_cost,

        CAST(
            SUM(shared_allocated_cost)
            AS NUMERIC
        ) AS shared_allocated_cost,

        CAST(
            SUM(unallocated_cost)
            AS NUMERIC
        ) AS unallocated_cost

    FROM provider_cost

    GROUP BY
        billing_month,
        application_name,
        department_name,
        cost_center,
        owner_name,
        billing_currency
),

combined_cost AS (
    SELECT
        billing_month,
        provider_name,
        application_name,
        department_name,
        cost_center,
        owner_name,
        billing_currency,
        allocation_row_count,
        source_record_count,
        total_allocated_cost,
        production_cost,
        nonproduction_cost,
        direct_cost,
        shared_allocated_cost,
        unallocated_cost

    FROM provider_cost

    UNION ALL

    SELECT
        billing_month,
        provider_name,
        application_name,
        department_name,
        cost_center,
        owner_name,
        billing_currency,
        allocation_row_count,
        source_record_count,
        total_allocated_cost,
        production_cost,
        nonproduction_cost,
        direct_cost,
        shared_allocated_cost,
        unallocated_cost

    FROM all_cloud_cost
),

cost_and_activity AS (
    SELECT
        cost.billing_month
            AS unit_economics_month,

        cost.provider_name,
        cost.application_name,
        cost.department_name,
        cost.cost_center,
        cost.owner_name,
        cost.billing_currency,

        cost.allocation_row_count,
        cost.source_record_count,

        cost.total_allocated_cost,
        cost.production_cost,
        cost.nonproduction_cost,
        cost.direct_cost,
        cost.shared_allocated_cost,
        cost.unallocated_cost,

        activity.activity_day_count,

        activity.traffic,
        activity.transactions,
        activity.queries,
        activity.support_requests,
        activity.ai_requests,
        activity.api_requests,

        activity.average_daily_active_customers,
        activity.peak_daily_active_customers,

        activity.revenue,

        COALESCE(
            activity.is_synthetic_activity,
            FALSE
        ) AS is_synthetic_activity,

        activity.application_name IS NOT NULL
            AS has_business_activity

    FROM combined_cost AS cost

    LEFT JOIN production_activity AS activity

        ON activity.activity_month
            = cost.billing_month

       AND activity.application_name
            = cost.application_name

       AND activity.department_name
            = cost.department_name

       AND activity.cost_center
            = cost.cost_center

       AND activity.owner_name
            = cost.owner_name
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                CAST(
                    unit_economics_month
                    AS STRING
                ),
                '|',
                provider_name,
                '|',
                application_name,
                '|',
                department_name,
                '|',
                cost_center,
                '|',
                billing_currency
            )
        )
    ) AS unit_economics_id,

    unit_economics_month,

    provider_name,
    application_name,
    department_name,
    cost_center,
    owner_name,

    billing_currency,

    allocation_row_count,
    source_record_count,

    total_allocated_cost,
    production_cost,
    nonproduction_cost,
    direct_cost,
    shared_allocated_cost,
    unallocated_cost,

    activity_day_count,

    traffic,
    transactions,
    queries,
    support_requests,
    ai_requests,
    api_requests,

    average_daily_active_customers,
    peak_daily_active_customers,

    revenue,

    CAST(
        SAFE_DIVIDE(
            total_allocated_cost,
            transactions
        )
        AS NUMERIC
    ) AS cost_per_transaction,

    CAST(
        SAFE_DIVIDE(
            total_allocated_cost,
            average_daily_active_customers
        )
        AS NUMERIC
    ) AS cost_per_active_customer,

    CAST(
        SAFE_DIVIDE(
            total_allocated_cost,
            api_requests
        )
        AS NUMERIC
    ) AS cost_per_api_request,

    CAST(
        SAFE_DIVIDE(
            total_allocated_cost,
            revenue
        )
        AS NUMERIC
    ) AS infrastructure_cost_pct_of_revenue,

    has_business_activity,
    is_synthetic_activity,

    'AVERAGE_DAILY_ACTIVE_CUSTOMERS'
        AS active_customer_basis,

    'PRODUCTION_BUSINESS_ACTIVITY'
        AS business_activity_scope,

    CASE
        WHEN application_name = 'Unallocated'
        THEN 'Pass with Exceptions'

        WHEN has_business_activity
        THEN 'Pass'

        ELSE 'Fail'
    END AS data_quality_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM cost_and_activity;

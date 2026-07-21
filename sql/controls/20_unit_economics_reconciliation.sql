/*
Purpose:
    Reconcile unit-economics activity and cost transformations.

Grain:
    One row per reconciliation check.

Source:
    Raw business activity
    Monthly activity
    Allocation fact
    Unit-economics cost base
    Unit-economics mart
    Unit-economics summary

Key controls:
    - Additive activity measures reconcile.
    - Provider cost reconciles to allocation.
    - Application unit-economics cost reconciles to the cost base.
    - ALL_CLOUD executive cost reconciles to allocation.
    - Same-source SQL tolerance is $0.01.

Owner:
    FinOps Analytics.

Refresh:
    After all unit-economics marts refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.unit_economics_reconciliation_control`

AS

WITH raw_activity AS (
    SELECT
        CAST(
            SUM(transactions)
            AS NUMERIC
        ) AS transactions,

        CAST(
            SUM(api_requests)
            AS NUMERIC
        ) AS api_requests,

        CAST(
            SUM(revenue)
            AS NUMERIC
        ) AS revenue

    FROM
        `__PROJECT_ID__.retail_finops_raw.raw_business_activity`
),

monthly_activity AS (
    SELECT
        CAST(
            SUM(transactions)
            AS NUMERIC
        ) AS transactions,

        CAST(
            SUM(api_requests)
            AS NUMERIC
        ) AS api_requests,

        CAST(
            SUM(revenue)
            AS NUMERIC
        ) AS revenue

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_business_activity_monthly`
),

allocation_cost AS (
    SELECT
        CAST(
            SUM(allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
),

cost_base AS (
    SELECT
        CAST(
            SUM(total_allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics_cost_base`
),

provider_unit_economics AS (
    SELECT
        CAST(
            SUM(total_allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics`

    WHERE provider_name <> 'ALL_CLOUD'
),

all_cloud_unit_economics AS (
    SELECT
        CAST(
            SUM(total_allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics`

    WHERE provider_name = 'ALL_CLOUD'
),

all_cloud_summary AS (
    SELECT
        CAST(
            SUM(total_allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics_summary`

    WHERE provider_name = 'ALL_CLOUD'
),

controls AS (
    SELECT
        'ACTIVITY_TRANSACTIONS_RECONCILIATION'
            AS check_name,

        raw.transactions
            AS source_control_total,

        monthly.transactions
            AS output_control_total,

        CAST(
            monthly.transactions
                - raw.transactions
            AS NUMERIC
        ) AS reconciliation_variance,

        NUMERIC '0.01'
            AS tolerance,

        CASE
            WHEN ABS(
                monthly.transactions
                    - raw.transactions
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Monthly transactions must reconcile to raw activity.'
            AS check_description

    FROM raw_activity AS raw

    CROSS JOIN monthly_activity AS monthly

    UNION ALL

    SELECT
        'ACTIVITY_API_REQUEST_RECONCILIATION',

        raw.api_requests,
        monthly.api_requests,

        CAST(
            monthly.api_requests
                - raw.api_requests
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                monthly.api_requests
                    - raw.api_requests
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Monthly API requests must reconcile to raw activity.'

    FROM raw_activity AS raw

    CROSS JOIN monthly_activity AS monthly

    UNION ALL

    SELECT
        'ACTIVITY_REVENUE_RECONCILIATION',

        raw.revenue,
        monthly.revenue,

        CAST(
            monthly.revenue
                - raw.revenue
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                monthly.revenue
                    - raw.revenue
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Monthly revenue must reconcile to raw activity.'

    FROM raw_activity AS raw

    CROSS JOIN monthly_activity AS monthly

    UNION ALL

    SELECT
        'ALLOCATION_TO_COST_BASE',

        allocation.total_allocated_cost,
        cost.total_allocated_cost,

        CAST(
            cost.total_allocated_cost
                - allocation.total_allocated_cost
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                cost.total_allocated_cost
                    - allocation.total_allocated_cost
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Unit-economics cost base must reconcile to allocation.'

    FROM allocation_cost AS allocation

    CROSS JOIN cost_base AS cost

    UNION ALL

    SELECT
        'COST_BASE_TO_PROVIDER_UNIT_ECONOMICS',

        cost.total_allocated_cost,
        unit_economics.total_allocated_cost,

        CAST(
            unit_economics.total_allocated_cost
                - cost.total_allocated_cost
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                unit_economics.total_allocated_cost
                    - cost.total_allocated_cost
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Provider unit-economics cost must reconcile to the cost base.'

    FROM cost_base AS cost

    CROSS JOIN provider_unit_economics
        AS unit_economics

    UNION ALL

    SELECT
        'ALL_CLOUD_UNIT_ECONOMICS_TO_ALLOCATION',

        allocation.total_allocated_cost,
        unit_economics.total_allocated_cost,

        CAST(
            unit_economics.total_allocated_cost
                - allocation.total_allocated_cost
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                unit_economics.total_allocated_cost
                    - allocation.total_allocated_cost
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'ALL_CLOUD application unit economics must reconcile to allocation.'

    FROM allocation_cost AS allocation

    CROSS JOIN all_cloud_unit_economics
        AS unit_economics

    UNION ALL

    SELECT
        'ALL_CLOUD_SUMMARY_TO_ALLOCATION',

        allocation.total_allocated_cost,
        summary.total_allocated_cost,

        CAST(
            summary.total_allocated_cost
                - allocation.total_allocated_cost
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                summary.total_allocated_cost
                    - allocation.total_allocated_cost
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Executive ALL_CLOUD cost must reconcile to allocation.'

    FROM allocation_cost AS allocation

    CROSS JOIN all_cloud_summary AS summary
)

SELECT
    check_name,
    source_control_total,
    output_control_total,
    reconciliation_variance,
    tolerance,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM controls;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.unit_economics_reconciliation_control`

ORDER BY check_name;

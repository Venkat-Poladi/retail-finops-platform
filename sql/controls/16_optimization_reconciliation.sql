/*
Purpose:
    Reconcile optimization baselines, eligible costs and lifecycle totals.

Grain:
    One row per optimization reconciliation control.

Source:
    mart_optimization
    optimization_source_detail
    mart_savings_funnel

Key controls:
    - Recommendation baselines reconcile to contributing source records.
    - Eligible costs reconcile to the eligible source population.
    - Identified and Realized funnel totals reconcile to recommendation records.
    - Same-source SQL tolerance is $0.01.

Owner:
    FinOps Analytics.

Refresh:
    After optimization source-detail and funnel refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.optimization_reconciliation_control`

AS

WITH detail_by_recommendation AS (
    SELECT
        recommendation_id,

        CAST(
            SUM(baseline_contribution_cost)
            AS NUMERIC
        ) AS detail_baseline_cost,

        CAST(
            SUM(eligible_contribution_cost)
            AS NUMERIC
        ) AS detail_eligible_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.optimization_source_detail`

    GROUP BY recommendation_id
),

recommendation_reconciliation AS (
    SELECT
        optimization.recommendation_id,

        optimization.baseline_cost,
        optimization.eligible_cost,

        COALESCE(
            detail.detail_baseline_cost,
            NUMERIC '0'
        ) AS detail_baseline_cost,

        COALESCE(
            detail.detail_eligible_cost,
            NUMERIC '0'
        ) AS detail_eligible_cost,

        CAST(
            COALESCE(
                detail.detail_baseline_cost,
                NUMERIC '0'
            )
                - optimization.baseline_cost
            AS NUMERIC
        ) AS baseline_variance,

        CAST(
            COALESCE(
                detail.detail_eligible_cost,
                NUMERIC '0'
            )
                - optimization.eligible_cost
            AS NUMERIC
        ) AS eligible_variance

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
            AS optimization

    LEFT JOIN detail_by_recommendation AS detail
        USING (recommendation_id)
),

identified_control AS (
    SELECT
        CAST(
            SUM(net_monthly_savings)
            AS NUMERIC
        ) AS recommendation_total,

        (
            SELECT monthly_savings

            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_savings_funnel`

            WHERE savings_stage = 'Identified'
        ) AS funnel_total

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`

    WHERE savings_stage NOT IN (
        'Rejected',
        'On Hold'
    )
),

realized_control AS (
    SELECT
        CAST(
            SUM(
                CASE
                    WHEN savings_stage = 'Realized'
                    THEN realized_savings
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS recommendation_total,

        (
            SELECT monthly_savings

            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_savings_funnel`

            WHERE savings_stage = 'Realized'
        ) AS funnel_total

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
),

controls AS (
    SELECT
        'RECOMMENDATION_BASELINE_TRACEABILITY'
            AS check_name,

        CAST(
            SUM(baseline_cost)
            AS NUMERIC
        ) AS source_control_total,

        CAST(
            SUM(detail_baseline_cost)
            AS NUMERIC
        ) AS output_control_total,

        CAST(
            SUM(detail_baseline_cost)
                - SUM(baseline_cost)
            AS NUMERIC
        ) AS reconciliation_variance,

        NUMERIC '0.01' AS tolerance,

        COUNTIF(
            ABS(baseline_variance)
                > NUMERIC '0.01'
        ) AS failed_record_count,

        CASE
            WHEN COUNTIF(
                ABS(baseline_variance)
                    > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'

            ELSE 'FAIL'
        END AS check_status,

        'Every recommendation baseline must reconcile to its source detail.'
            AS check_description

    FROM recommendation_reconciliation

    UNION ALL

    SELECT
        'RECOMMENDATION_ELIGIBLE_COST_TRACEABILITY',

        CAST(
            SUM(eligible_cost)
            AS NUMERIC
        ),

        CAST(
            SUM(detail_eligible_cost)
            AS NUMERIC
        ),

        CAST(
            SUM(detail_eligible_cost)
                - SUM(eligible_cost)
            AS NUMERIC
        ),

        NUMERIC '0.01',

        COUNTIF(
            ABS(eligible_variance)
                > NUMERIC '0.01'
        ),

        CASE
            WHEN COUNTIF(
                ABS(eligible_variance)
                    > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'

            ELSE 'FAIL'
        END,

        'Every eligible-cost calculation must reconcile to source detail.'

    FROM recommendation_reconciliation

    UNION ALL

    SELECT
        'IDENTIFIED_FUNNEL_RECONCILIATION',
        recommendation_total,
        funnel_total,

        CAST(
            funnel_total
                - recommendation_total
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                funnel_total
                    - recommendation_total
            ) > NUMERIC '0.01'
            THEN 1
            ELSE 0
        END,

        CASE
            WHEN ABS(
                funnel_total
                    - recommendation_total
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Identified funnel savings must equal total active net savings.'

    FROM identified_control

    UNION ALL

    SELECT
        'REALIZED_FUNNEL_RECONCILIATION',
        recommendation_total,
        funnel_total,

        CAST(
            funnel_total
                - recommendation_total
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN ABS(
                funnel_total
                    - recommendation_total
            ) > NUMERIC '0.01'
            THEN 1
            ELSE 0
        END,

        CASE
            WHEN ABS(
                funnel_total
                    - recommendation_total
            ) <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Realized funnel savings must equal modeled realized savings.'

    FROM realized_control
)

SELECT
    check_name,
    source_control_total,
    output_control_total,
    reconciliation_variance,
    tolerance,
    failed_record_count,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM controls;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.optimization_reconciliation_control`

ORDER BY check_name;

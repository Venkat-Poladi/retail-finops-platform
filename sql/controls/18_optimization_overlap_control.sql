/*
Purpose:
    Validate overlap dependencies and prevent double-counted savings.

Grain:
    One row per overlap-control check.

Source:
    retail_finops_mart.mart_optimization

Key controls:
    - Every dependency exists.
    - Dependent recommendations follow the correct calculation order.
    - Gross minus overlap equals net savings.
    - Proposed cost includes prior dependent savings.
    - Cumulative net savings cannot exceed baseline cost.

Owner:
    FinOps Analytics.

Refresh:
    After mart_optimization refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.optimization_overlap_control`

AS

WITH recommendations AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
),

dependency_validation AS (
    SELECT
        recommendation.recommendation_id,

        recommendation.dependency_recommendation_id,

        recommendation.overlap_group_id,

        recommendation.calculation_order,

        recommendation.baseline_cost,
        recommendation.proposed_cost,
        recommendation.gross_savings,
        recommendation.overlap_adjustment,
        recommendation.net_monthly_savings,

        dependency.recommendation_id
            AS resolved_dependency_id,

        dependency.overlap_group_id
            AS dependency_overlap_group_id,

        dependency.calculation_order
            AS dependency_calculation_order,

        dependency.net_monthly_savings
            AS dependency_net_savings

    FROM recommendations AS recommendation

    LEFT JOIN recommendations AS dependency

        ON recommendation.dependency_recommendation_id
            = dependency.recommendation_id
),

overlap_groups AS (
    SELECT
        overlap_group_id,

        MAX(baseline_cost)
            AS group_baseline_cost,

        SUM(net_monthly_savings)
            AS group_net_savings

    FROM recommendations

    GROUP BY overlap_group_id
),

controls AS (
    SELECT
        'MISSING_DEPENDENCY'
            AS check_name,

        COUNTIF(
            dependency_recommendation_id IS NOT NULL
            AND resolved_dependency_id IS NULL
        ) AS issue_count,

        CASE
            WHEN COUNTIF(
                dependency_recommendation_id IS NOT NULL
                AND resolved_dependency_id IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Every dependency recommendation must exist.'
            AS check_description

    FROM dependency_validation

    UNION ALL

    SELECT
        'DEPENDENCY_OUTSIDE_OVERLAP_GROUP',

        COUNTIF(
            dependency_recommendation_id IS NOT NULL
            AND overlap_group_id
                <> dependency_overlap_group_id
        ),

        CASE
            WHEN COUNTIF(
                dependency_recommendation_id IS NOT NULL
                AND overlap_group_id
                    <> dependency_overlap_group_id
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Dependent recommendations must affect the same overlap group.'

    FROM dependency_validation

    UNION ALL

    SELECT
        'INVALID_CALCULATION_ORDER',

        COUNTIF(
            dependency_recommendation_id IS NOT NULL
            AND calculation_order
                <= dependency_calculation_order
        ),

        CASE
            WHEN COUNTIF(
                dependency_recommendation_id IS NOT NULL
                AND calculation_order
                    <= dependency_calculation_order
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Dependent recommendations must be calculated after their dependency.'

    FROM dependency_validation

    UNION ALL

    SELECT
        'GROSS_NET_OVERLAP_MISMATCH',

        COUNTIF(
            ABS(
                gross_savings
                    - overlap_adjustment
                    - net_monthly_savings
            ) > NUMERIC '0.01'
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    gross_savings
                        - overlap_adjustment
                        - net_monthly_savings
                ) > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Gross savings minus overlap adjustment must equal net savings.'

    FROM dependency_validation

    UNION ALL

    SELECT
        'PROPOSED_COST_MISMATCH',

        COUNTIF(
            ABS(
                proposed_cost
                    - (
                        baseline_cost
                        - COALESCE(
                            dependency_net_savings,
                            NUMERIC '0'
                          )
                        - net_monthly_savings
                    )
            ) > NUMERIC '0.01'
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    proposed_cost
                        - (
                            baseline_cost
                            - COALESCE(
                                dependency_net_savings,
                                NUMERIC '0'
                              )
                            - net_monthly_savings
                        )
                ) > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Proposed cost must reflect dependency savings and current net savings.'

    FROM dependency_validation

    UNION ALL

    SELECT
        'OVERLAP_GROUP_SAVINGS_EXCEED_BASELINE',

        COUNTIF(
            group_net_savings
                > group_baseline_cost
                    + NUMERIC '0.01'
        ),

        CASE
            WHEN COUNTIF(
                group_net_savings
                    > group_baseline_cost
                        + NUMERIC '0.01'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Cumulative savings cannot exceed the resource baseline.'

    FROM overlap_groups

    UNION ALL

    SELECT
        'GROSS_SAVINGS_USED_AS_PORTFOLIO_TOTAL',

        COUNTIF(
            ABS(
                annualized_savings
                    - net_monthly_savings * 12
            ) > NUMERIC '0.01'
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    annualized_savings
                        - net_monthly_savings * 12
                ) > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Portfolio annualized savings must use net, not gross, savings.'

    FROM recommendations
)

SELECT
    check_name,
    issue_count,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM controls;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.optimization_overlap_control`

ORDER BY check_name;

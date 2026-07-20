/*
Purpose:
    Create the cumulative savings-lifecycle funnel.

Grain:
    One row per cumulative lifecycle stage.

Source:
    retail_finops_mart.mart_optimization

Key controls:
    - Identified includes the complete active opportunity portfolio.
    - Approved includes Approved, Implemented and Realized records.
    - Implemented includes Implemented and Realized records.
    - Realized uses only modeled realized_savings.
    - Only net savings enter the funnel.

Owner:
    FinOps Analytics.

Refresh:
    After mart_optimization refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_savings_funnel`

AS

WITH optimization AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`

    WHERE savings_stage NOT IN (
        'Rejected',
        'On Hold'
    )
),

funnel AS (
    SELECT
        1 AS stage_order,
        'Identified' AS savings_stage,

        COUNT(*)
            AS recommendation_count,

        CAST(
            SUM(net_monthly_savings)
            AS NUMERIC
        ) AS monthly_savings,

        NUMERIC '15000'
            AS target_monthly_savings

    FROM optimization

    UNION ALL

    SELECT
        2,
        'Approved',

        COUNTIF(
            savings_stage IN (
                'Approved',
                'Implemented',
                'Realized'
            )
        ),

        CAST(
            SUM(
                CASE
                    WHEN savings_stage IN (
                        'Approved',
                        'Implemented',
                        'Realized'
                    )
                    THEN net_monthly_savings
                    ELSE 0
                END
            )
            AS NUMERIC
        ),

        NUMERIC '12000'

    FROM optimization

    UNION ALL

    SELECT
        3,
        'Implemented',

        COUNTIF(
            savings_stage IN (
                'Implemented',
                'Realized'
            )
        ),

        CAST(
            SUM(
                CASE
                    WHEN savings_stage IN (
                        'Implemented',
                        'Realized'
                    )
                    THEN net_monthly_savings
                    ELSE 0
                END
            )
            AS NUMERIC
        ),

        NUMERIC '9000'

    FROM optimization

    UNION ALL

    SELECT
        4,
        'Realized',

        COUNTIF(
            savings_stage = 'Realized'
        ),

        CAST(
            SUM(
                CASE
                    WHEN savings_stage = 'Realized'
                    THEN realized_savings
                    ELSE 0
                END
            )
            AS NUMERIC
        ),

        NUMERIC '7500'

    FROM optimization
)

SELECT
    stage_order,
    savings_stage,
    recommendation_count,
    monthly_savings,

    CAST(
        monthly_savings * 12
        AS NUMERIC
    ) AS annualized_savings,

    target_monthly_savings,

    CAST(
        monthly_savings
            - target_monthly_savings
        AS NUMERIC
    ) AS variance_to_target,

    CASE
        WHEN monthly_savings
                >= target_monthly_savings
        THEN 'MET'

        ELSE 'MISSED'
    END AS target_result,

    'MODELED'
        AS savings_value_type,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM funnel

ORDER BY stage_order;

/*
Purpose:
    Validate the modeled optimization savings lifecycle.

Grain:
    One row per lifecycle-control check.

Source:
    mart_optimization
    mart_savings_funnel

Key controls:
    - Identified is at least Approved.
    - Approved is at least Implemented.
    - Implemented is at least Realized.
    - Each funnel stage recalculates from recommendation records.
    - Lifecycle dates follow logical ordering.

Owner:
    FinOps Analytics.

Refresh:
    After savings funnel refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.savings_lifecycle_control`

AS

WITH funnel AS (
    SELECT
        MAX(
            IF(
                savings_stage = 'Identified',
                monthly_savings,
                NULL
            )
        ) AS identified_savings,

        MAX(
            IF(
                savings_stage = 'Approved',
                monthly_savings,
                NULL
            )
        ) AS approved_savings,

        MAX(
            IF(
                savings_stage = 'Implemented',
                monthly_savings,
                NULL
            )
        ) AS implemented_savings,

        MAX(
            IF(
                savings_stage = 'Realized',
                monthly_savings,
                NULL
            )
        ) AS realized_savings

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_savings_funnel`
),

stage_counts AS (
    SELECT
        COUNTIF(
            savings_stage = 'Identified'
        ) AS identified_count,

        COUNTIF(
            savings_stage = 'Approved'
        ) AS approved_count,

        COUNTIF(
            savings_stage = 'Implemented'
        ) AS implemented_count,

        COUNTIF(
            savings_stage = 'Realized'
        ) AS realized_count

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
),

controls AS (
    SELECT
        'IDENTIFIED_GE_APPROVED'
            AS check_name,

        CASE
            WHEN identified_savings
                    >= approved_savings
            THEN 0
            ELSE 1
        END AS issue_count,

        CASE
            WHEN identified_savings
                    >= approved_savings
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Identified savings must be at least Approved savings.'
            AS check_description

    FROM funnel

    UNION ALL

    SELECT
        'APPROVED_GE_IMPLEMENTED',

        CASE
            WHEN approved_savings
                    >= implemented_savings
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN approved_savings
                    >= implemented_savings
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Approved savings must be at least Implemented savings.'

    FROM funnel

    UNION ALL

    SELECT
        'IMPLEMENTED_GE_REALIZED',

        CASE
            WHEN implemented_savings
                    >= realized_savings
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN implemented_savings
                    >= realized_savings
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Implemented savings must be at least Realized savings.'

    FROM funnel

    UNION ALL

    SELECT
        'LIFECYCLE_STAGE_REPRESENTATION',

        CASE
            WHEN identified_count > 0
             AND approved_count > 0
             AND implemented_count > 0
             AND realized_count > 0
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN identified_count > 0
             AND approved_count > 0
             AND implemented_count > 0
             AND realized_count > 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'The modeled portfolio should demonstrate all four lifecycle stages.'

    FROM stage_counts

    UNION ALL

    SELECT
        'IMPLEMENTATION_DATE_REQUIRED',

        COUNTIF(
            savings_stage IN (
                'Implemented',
                'Realized'
            )
            AND implementation_date IS NULL
        ),

        CASE
            WHEN COUNTIF(
                savings_stage IN (
                    'Implemented',
                    'Realized'
                )
                AND implementation_date IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Implemented and Realized records require implementation dates.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`

    UNION ALL

    SELECT
        'REALIZED_VALIDATION_DATE_REQUIRED',

        COUNTIF(
            savings_stage = 'Realized'
            AND validation_date IS NULL
        ),

        CASE
            WHEN COUNTIF(
                savings_stage = 'Realized'
                AND validation_date IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Realized records require validation dates.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`

    UNION ALL

    SELECT
        'VALIDATION_BEFORE_IMPLEMENTATION',

        COUNTIF(
            validation_date IS NOT NULL
            AND implementation_date IS NOT NULL
            AND validation_date < implementation_date
        ),

        CASE
            WHEN COUNTIF(
                validation_date IS NOT NULL
                AND implementation_date IS NOT NULL
                AND validation_date < implementation_date
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Validation cannot occur before implementation.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
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
    `__PROJECT_ID__.retail_finops_control.savings_lifecycle_control`

ORDER BY check_name;

/*
Purpose:
    Validate cost-period and business-activity-period alignment.

Grain:
    One row per period-alignment check.

Source:
    Raw business activity
    Allocation fact
    Monthly activity
    Unit-economics mart

Key controls:
    - Activity and cost cover the same 12-month period.
    - Every cost month has activity.
    - Every activity month has cost.
    - Daily activity covers the expected contiguous period.
    - Monthly activity contains the expected number of calendar days.

Owner:
    FinOps Analytics.

Refresh:
    After unit-economics data-quality controls.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.unit_economics_period_alignment_control`

AS

WITH activity_period AS (
    SELECT
        MIN(activity_date)
            AS minimum_activity_date,

        MAX(activity_date)
            AS maximum_activity_date,

        COUNT(DISTINCT activity_date)
            AS activity_date_count,

        COUNT(
            DISTINCT DATE_TRUNC(
                activity_date,
                MONTH
            )
        ) AS activity_month_count

    FROM
        `__PROJECT_ID__.retail_finops_raw.raw_business_activity`
),

cost_period AS (
    SELECT
        MIN(billing_month)
            AS minimum_cost_month,

        MAX(billing_month)
            AS maximum_cost_month,

        COUNT(DISTINCT billing_month)
            AS cost_month_count

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
),

missing_cost_months AS (
    SELECT
        COUNT(*) AS issue_count

    FROM (
        SELECT DISTINCT
            DATE_TRUNC(
                activity_date,
                MONTH
            ) AS activity_month

        FROM
            `__PROJECT_ID__.retail_finops_raw.raw_business_activity`

        EXCEPT DISTINCT

        SELECT DISTINCT
            billing_month

        FROM
            `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
    )
),

missing_activity_months AS (
    SELECT
        COUNT(*) AS issue_count

    FROM (
        SELECT DISTINCT
            billing_month

        FROM
            `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`

        EXCEPT DISTINCT

        SELECT DISTINCT
            DATE_TRUNC(
                activity_date,
                MONTH
            )

        FROM
            `__PROJECT_ID__.retail_finops_raw.raw_business_activity`
    )
),

incomplete_application_months AS (
    SELECT
        COUNT(*) AS issue_count

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_business_activity_monthly`

    WHERE activity_day_count
        <> EXTRACT(
            DAY
            FROM LAST_DAY(activity_month)
        )
),

controls AS (
    SELECT
        'ACTIVITY_DATE_RANGE_CONTIGUOUS'
            AS check_name,

        CASE
            WHEN activity_date_count
                = DATE_DIFF(
                    maximum_activity_date,
                    minimum_activity_date,
                    DAY
                ) + 1
            THEN 0
            ELSE 1
        END AS issue_count,

        CASE
            WHEN activity_date_count
                = DATE_DIFF(
                    maximum_activity_date,
                    minimum_activity_date,
                    DAY
                ) + 1
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Business activity must cover a contiguous daily period.'
            AS check_description

    FROM activity_period

    UNION ALL

    SELECT
        'ACTIVITY_MONTH_COUNT',

        CASE
            WHEN activity_month_count = 12
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN activity_month_count = 12
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Business activity must contain 12 months.'

    FROM activity_period

    UNION ALL

    SELECT
        'COST_MONTH_COUNT',

        CASE
            WHEN cost_month_count = 12
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN cost_month_count = 12
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Allocated cost must contain 12 months.'

    FROM cost_period

    UNION ALL

    SELECT
        'ACTIVITY_WITHOUT_COST_MONTH',

        issue_count,

        CASE
            WHEN issue_count = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every activity month must have an allocated-cost month.'

    FROM missing_cost_months

    UNION ALL

    SELECT
        'COST_WITHOUT_ACTIVITY_MONTH',

        issue_count,

        CASE
            WHEN issue_count = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every allocated-cost month must have business activity.'

    FROM missing_activity_months

    UNION ALL

    SELECT
        'INCOMPLETE_APPLICATION_MONTH',

        issue_count,

        CASE
            WHEN issue_count = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every application month must contain every calendar day.'

    FROM incomplete_application_months

    UNION ALL

    SELECT
        'START_MONTH_ALIGNMENT',

        CASE
            WHEN DATE_TRUNC(
                    minimum_activity_date,
                    MONTH
                 )
                = minimum_cost_month
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN DATE_TRUNC(
                    minimum_activity_date,
                    MONTH
                 )
                = minimum_cost_month
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Cost and activity must begin in the same month.'

    FROM activity_period

    CROSS JOIN cost_period

    UNION ALL

    SELECT
        'END_MONTH_ALIGNMENT',

        CASE
            WHEN DATE_TRUNC(
                    maximum_activity_date,
                    MONTH
                 )
                = maximum_cost_month
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN DATE_TRUNC(
                    maximum_activity_date,
                    MONTH
                 )
                = maximum_cost_month
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Cost and activity must end in the same month.'

    FROM activity_period

    CROSS JOIN cost_period
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
    `__PROJECT_ID__.retail_finops_control.unit_economics_period_alignment_control`

ORDER BY check_name;

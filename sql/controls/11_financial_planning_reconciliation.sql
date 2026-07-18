/*
Purpose:
    Reconcile financial-planning and monthly-close outputs.

Grain:
    One row per financial control.

Source:
    Fact, allocation, planning and close tables.

Key controls:
    - Actuals reconcile to allocation and fact.
    - Forecast accuracy is calculated.
    - Variance decomposition reconciles.
    - Accruals and reversals net to zero.
    - Reclasses net to zero.
    - Chargeback journals net to zero.
    - Chargeback target lines reconcile to allocated cost.

Owner:
    Finance and FinOps.

Refresh:
    After monthly-close outputs.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.financial_planning_reconciliation_control`

AS

WITH metrics AS (
    SELECT
        (
            SELECT SUM(actual_cost)
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
        ) AS monthly_actual_cost,

        (
            SELECT SUM(allocated_cost)
            FROM
                `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
        ) AS allocation_cost,

        (
            SELECT SUM(billed_cost)
            FROM
                `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
        ) AS fact_cost,

        (
            SELECT COUNT(*)
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_budget`
        ) AS budget_row_count,

        (
            SELECT COUNT(*)
            FROM
                `__PROJECT_ID__.retail_finops_mart.fct_forecast_version`
        ) AS forecast_version_count,

        (
            SELECT COUNTIF(forecast_mape IS NOT NULL)
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_forecast_accuracy`
        ) AS forecast_accuracy_count,

        (
            SELECT COALESCE(
                MAX(ABS(decomposition_variance)),
                0
            )
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_variance_drivers`
        ) AS maximum_decomposition_variance,

        (
            SELECT
                COALESCE(
                    (
                        SELECT SUM(accrual_amount)
                        FROM
                            `__PROJECT_ID__.retail_finops_mart.fct_cloud_accrual`
                    ),
                    0
                )
                +
                COALESCE(
                    (
                        SELECT SUM(reversal_amount)
                        FROM
                            `__PROJECT_ID__.retail_finops_mart.fct_accrual_reversal`
                    ),
                    0
                )
        ) AS accrual_reversal_net,

        (
            SELECT COALESCE(
                MAX(ABS(journal_net)),
                0
            )
            FROM (
                SELECT
                    journal_id,
                    SUM(journal_amount)
                        AS journal_net

                FROM
                    `__PROJECT_ID__.retail_finops_mart.fct_reclass_journal`

                GROUP BY journal_id
            )
        ) AS maximum_reclass_journal_variance,

        (
            SELECT COALESCE(
                MAX(ABS(journal_net)),
                0
            )
            FROM (
                SELECT
                    journal_id,
                    SUM(journal_amount)
                        AS journal_net

                FROM
                    `__PROJECT_ID__.retail_finops_mart.fct_chargeback_journal`

                GROUP BY journal_id
            )
        ) AS maximum_chargeback_journal_variance,

        (
            SELECT SUM(journal_amount)
            FROM
                `__PROJECT_ID__.retail_finops_mart.fct_chargeback_journal`

            WHERE journal_line_role = 'TARGET_COST_CENTER'
        ) AS chargeback_target_cost,

        (
            SELECT COUNTIF(
                owner IS NULL
                OR TRIM(owner) = ''
                OR due_date IS NULL
                OR status IS NULL
                OR TRIM(status) = ''
            )
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_close_checklist`
        ) AS incomplete_checklist_metadata
),

controls AS (
    SELECT
        'MONTHLY_ACTUAL_TO_ALLOCATION'
            AS check_name,

        CAST(
            monthly_actual_cost - allocation_cost
            AS NUMERIC
        ) AS measured_variance,

        CAST(0.01 AS NUMERIC)
            AS tolerance,

        CASE
            WHEN ABS(
                monthly_actual_cost - allocation_cost
            ) <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Monthly actual cost must reconcile to allocation.'
            AS check_description

    FROM metrics

    UNION ALL

    SELECT
        'MONTHLY_ACTUAL_TO_FACT',

        CAST(
            monthly_actual_cost - fact_cost
            AS NUMERIC
        ),

        CAST(0.01 AS NUMERIC),

        CASE
            WHEN ABS(
                monthly_actual_cost - fact_cost
            ) <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Monthly actual cost must reconcile to approved fact cost.'

    FROM metrics

    UNION ALL

    SELECT
        'BUDGET_ROWS_AVAILABLE',

        CAST(budget_row_count AS NUMERIC),

        CAST(1 AS NUMERIC),

        CASE
            WHEN budget_row_count > 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Modeled approved-budget rows must exist.'

    FROM metrics

    UNION ALL

    SELECT
        'FORECAST_VERSIONS_AVAILABLE',

        CAST(forecast_version_count AS NUMERIC),

        CAST(1 AS NUMERIC),

        CASE
            WHEN forecast_version_count > 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Historical forecast versions must exist.'

    FROM metrics

    UNION ALL

    SELECT
        'FORECAST_ACCURACY_AVAILABLE',

        CAST(forecast_accuracy_count AS NUMERIC),

        CAST(1 AS NUMERIC),

        CASE
            WHEN forecast_accuracy_count > 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Forecast MAPE and bias must be calculated.'

    FROM metrics

    UNION ALL

    SELECT
        'USAGE_RATE_SCOPE_RECONCILIATION',

        CAST(maximum_decomposition_variance AS NUMERIC),

        CAST(0.01 AS NUMERIC),

        CASE
            WHEN maximum_decomposition_variance <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Usage, rate and scope effects must reconcile to cost change.'

    FROM metrics

    UNION ALL

    SELECT
        'ACCRUAL_REVERSAL_NET',

        CAST(accrual_reversal_net AS NUMERIC),

        CAST(0.01 AS NUMERIC),

        CASE
            WHEN ABS(accrual_reversal_net) <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Accruals and reversals must net to zero.'

    FROM metrics

    UNION ALL

    SELECT
        'RECLASS_JOURNAL_NET',

        CAST(maximum_reclass_journal_variance AS NUMERIC),

        CAST(0.01 AS NUMERIC),

        CASE
            WHEN maximum_reclass_journal_variance <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every reclass journal must net to zero.'

    FROM metrics

    UNION ALL

    SELECT
        'CHARGEBACK_JOURNAL_NET',

        CAST(maximum_chargeback_journal_variance AS NUMERIC),

        CAST(0.01 AS NUMERIC),

        CASE
            WHEN maximum_chargeback_journal_variance <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every chargeback journal must net to zero.'

    FROM metrics

    UNION ALL

    SELECT
        'CHARGEBACK_TO_ALLOCATION',

        CAST(
            chargeback_target_cost - allocation_cost
            AS NUMERIC
        ),

        CAST(0.01 AS NUMERIC),

        CASE
            WHEN ABS(
                chargeback_target_cost - allocation_cost
            ) <= 0.01
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Target chargeback lines must reconcile to allocated cost.'

    FROM metrics

    UNION ALL

    SELECT
        'CLOSE_CHECKLIST_METADATA',

        CAST(
            incomplete_checklist_metadata
            AS NUMERIC
        ),

        CAST(0 AS NUMERIC),

        CASE
            WHEN incomplete_checklist_metadata = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every checklist row must have owner, due date and status.'

    FROM metrics
)

SELECT
    check_name,
    measured_variance,
    tolerance,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM controls;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.financial_planning_reconciliation_control`

ORDER BY check_name;
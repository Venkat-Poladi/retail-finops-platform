/*
Purpose:
    Create the current monthly-close checklist with owner,
    due date, status and evidence.

Grain:
    One row per close task.

Source:
    Planning, allocation and journal tables.

Key controls:
    - Every task has an owner.
    - Every task has a due date.
    - Every task has a status.
    - Automated tasks use calculated evidence.
    - Final finance sign-off remains manual.

Owner:
    Finance and FinOps.

Refresh:
    After planning and journal controls.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_close_checklist`

AS

WITH close_context AS (
    SELECT
        MAX(billing_month)
            AS close_month

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
),

metrics AS (
    SELECT
        close_month,

        (
            SELECT COUNT(*)
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
        ) AS monthly_actual_rows,

        (
            SELECT ABS(
                SUM(actual_cost)
                -
                (
                    SELECT SUM(allocated_cost)
                    FROM
                        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
                )
            )
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
        ) AS monthly_actual_variance,

        (
            SELECT COUNT(*)
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_budget`
        ) AS budget_rows,

        (
            SELECT COUNT(*)
            FROM
                `__PROJECT_ID__.retail_finops_mart.fct_forecast_version`
        ) AS forecast_rows,

        (
            SELECT COUNTIF(forecast_mape IS NOT NULL)
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_forecast_accuracy`
        ) AS forecast_accuracy_rows,

        (
            SELECT COUNTIF(decomposition_status = 'FAIL')
            FROM
                `__PROJECT_ID__.retail_finops_mart.mart_variance_drivers`
        ) AS decomposition_failures,

        (
            SELECT ABS(
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
            )
        ) AS accrual_reversal_variance,

        (
            SELECT COUNT(*)
            FROM (
                SELECT
                    journal_id

                FROM
                    `__PROJECT_ID__.retail_finops_mart.fct_reclass_journal`

                GROUP BY journal_id

                HAVING ABS(SUM(journal_amount)) > 0.01
            )
        ) AS unbalanced_reclass_journals,

        (
            SELECT COUNT(*)
            FROM (
                SELECT
                    journal_id

                FROM
                    `__PROJECT_ID__.retail_finops_mart.fct_chargeback_journal`

                GROUP BY journal_id

                HAVING ABS(SUM(journal_amount)) > 0.01
            )
        ) AS unbalanced_chargeback_journals

    FROM close_context
),

tasks AS (
    SELECT
        1 AS task_sequence,
        'MONTHLY_ACTUALS_REFRESH'
            AS task_id,
        'Refresh monthly actual cost'
            AS task_name,
        'FinOps Data Analyst'
            AS owner,
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 1 DAY
        ) AS due_date,
        CASE
            WHEN monthly_actual_rows > 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END AS status,
        'retail_finops_mart.mart_monthly_actuals'
            AS evidence_object

    FROM metrics

    UNION ALL

    SELECT
        2,
        'MONTHLY_ACTUALS_RECONCILIATION',
        'Reconcile monthly actuals to allocated cost',
        'FinOps Lead',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 2 DAY
        ),
        CASE
            WHEN monthly_actual_variance <= 0.01
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'Monthly actual variance <= $0.01'

    FROM metrics

    UNION ALL

    SELECT
        3,
        'BUDGET_REFRESH',
        'Refresh approved modeled budget',
        'Finance Business Partner',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 2 DAY
        ),
        CASE
            WHEN budget_rows > 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'retail_finops_mart.mart_budget'

    FROM metrics

    UNION ALL

    SELECT
        4,
        'FORECAST_REFRESH',
        'Create and preserve forecast version',
        'FinOps Analyst',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 2 DAY
        ),
        CASE
            WHEN forecast_rows > 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'retail_finops_mart.fct_forecast_version'

    FROM metrics

    UNION ALL

    SELECT
        5,
        'FORECAST_ACCURACY',
        'Calculate forecast MAPE and bias',
        'FinOps Analyst',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 3 DAY
        ),
        CASE
            WHEN forecast_accuracy_rows > 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'retail_finops_mart.mart_forecast_accuracy'

    FROM metrics

    UNION ALL

    SELECT
        6,
        'VARIANCE_DECOMPOSITION',
        'Complete usage rate and scope analysis',
        'FinOps Analyst',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 3 DAY
        ),
        CASE
            WHEN decomposition_failures = 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'retail_finops_mart.mart_variance_drivers'

    FROM metrics

    UNION ALL

    SELECT
        7,
        'ACCRUAL_AND_REVERSAL',
        'Post accruals and create reversals',
        'Cloud Accounting',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 3 DAY
        ),
        CASE
            WHEN accrual_reversal_variance <= 0.01
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'Accrual plus reversal variance <= $0.01'

    FROM metrics

    UNION ALL

    SELECT
        8,
        'RECLASS_REVIEW',
        'Review and post shared-cost reclasses',
        'Cloud Accounting',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 3 DAY
        ),
        CASE
            WHEN unbalanced_reclass_journals = 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'All reclass journals net to zero'

    FROM metrics

    UNION ALL

    SELECT
        9,
        'CHARGEBACK_JOURNAL',
        'Review chargeback journal',
        'Finance Operations',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 4 DAY
        ),
        CASE
            WHEN unbalanced_chargeback_journals = 0
            THEN 'COMPLETED'
            ELSE 'BLOCKED'
        END,
        'All chargeback journals net to zero'

    FROM metrics

    UNION ALL

    SELECT
        10,
        'FINANCE_CLOSE_SIGN_OFF',
        'Approve monthly cloud financial close',
        'Finance Controller',
        DATE_ADD(
            LAST_DAY(close_month),
            INTERVAL 4 DAY
        ),
        'PENDING',
        'Manual controller approval required'

    FROM metrics
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                CAST(close_month AS STRING),
                '|',
                task_id
            )
        )
    ) AS checklist_item_id,

    close_month,
    task_sequence,
    task_id,
    task_name,
    owner,
    due_date,
    status,
    evidence_object,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM tasks

CROSS JOIN (
    SELECT
        MAX(billing_month)
            AS close_month

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
);

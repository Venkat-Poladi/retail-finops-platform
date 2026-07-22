/*
Purpose:
    Validate financial-planning and monthly-close data quality.

Grain:
    One row per quality check.

Source:
    Budget, forecast, variance, accrual, reversal, reclass,
    chargeback and close-checklist tables.

Key controls:
    - IDs are complete and unique.
    - Required financial amounts are populated.
    - Journals contain two lines and net to zero.
    - Reversals retain accrual lineage.
    - Checklist vocabulary is controlled.

Owner:
    Finance and FinOps.

Refresh:
    After financial reconciliation.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.monthly_close_data_quality_control`

AS

WITH quality_checks AS (
    SELECT
        'DUPLICATE_BUDGET_RECORD_ID'
            AS check_name,

        'ERROR' AS severity,

        COUNT(*) AS issue_count,

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'budget_record_id must be unique.'
            AS check_description

    FROM (
        SELECT
            budget_record_id

        FROM
            `__PROJECT_ID__.retail_finops_mart.mart_budget`

        GROUP BY budget_record_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'NULL_APPROVED_BUDGET',
        'ERROR',

        COUNTIF(approved_budget_cost IS NULL),

        CASE
            WHEN COUNTIF(
                approved_budget_cost IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every budget row must contain approved_budget_cost.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_budget`

    UNION ALL

    SELECT
        'DUPLICATE_FORECAST_VERSION_ID',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'forecast_version_id must be unique.'

    FROM (
        SELECT
            forecast_version_id

        FROM
            `__PROJECT_ID__.retail_finops_mart.fct_forecast_version`

        GROUP BY forecast_version_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'NULL_FORECAST_COST',
        'ERROR',

        COUNTIF(forecast_cost IS NULL),

        CASE
            WHEN COUNTIF(
                forecast_cost IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every forecast version must contain forecast_cost.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_forecast_version`

    UNION ALL

    SELECT
        'VARIANCE_DECOMPOSITION_FAILURE',
        'ERROR',

        COUNTIF(decomposition_status = 'FAIL'),

        CASE
            WHEN COUNTIF(
                decomposition_status = 'FAIL'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Usage, rate and scope decomposition must reconcile.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_variance_drivers`

    UNION ALL

    SELECT
        'DUPLICATE_ACCRUAL_ID',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'accrual_id must be unique.'

    FROM (
        SELECT
            accrual_id

        FROM
            `__PROJECT_ID__.retail_finops_mart.fct_cloud_accrual`

        GROUP BY accrual_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'REVERSAL_WITHOUT_ACCRUAL',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every reversal must link to an accrual.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_accrual_reversal`
            AS reversal

    LEFT JOIN
        `__PROJECT_ID__.retail_finops_mart.fct_cloud_accrual`
            AS accrual

        USING (accrual_id)

    WHERE accrual.accrual_id IS NULL

    UNION ALL

    SELECT
        'ACCRUAL_REVERSAL_AMOUNT_MISMATCH',
        'ERROR',

        COUNTIF(
            ABS(
                accrual.accrual_amount
                + reversal.reversal_amount
            ) > 0.01
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    accrual.accrual_amount
                    + reversal.reversal_amount
                ) > 0.01
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Each reversal must equal the negative accrual amount.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_cloud_accrual`
            AS accrual

    LEFT JOIN
        `__PROJECT_ID__.retail_finops_mart.fct_accrual_reversal`
            AS reversal

        USING (accrual_id)

    UNION ALL

    SELECT
        'RECLASS_JOURNAL_LINE_COUNT',
        'ERROR',

        COUNTIF(journal_line_count != 2),

        CASE
            WHEN COUNTIF(
                journal_line_count != 2
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every reclass journal must contain two lines.'

    FROM (
        SELECT
            journal_id,
            COUNT(*) AS journal_line_count

        FROM
            `__PROJECT_ID__.retail_finops_mart.fct_reclass_journal`

        GROUP BY journal_id
    )

    UNION ALL

    SELECT
        'RECLASS_JOURNAL_NOT_BALANCED',
        'ERROR',

        COUNTIF(ABS(journal_total) > 0.01),

        CASE
            WHEN COUNTIF(
                ABS(journal_total) > 0.01
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every reclass journal must net to zero.'

    FROM (
        SELECT
            journal_id,
            SUM(journal_amount)
                AS journal_total

        FROM
            `__PROJECT_ID__.retail_finops_mart.fct_reclass_journal`

        GROUP BY journal_id
    )

    UNION ALL

    SELECT
        'CHARGEBACK_JOURNAL_LINE_COUNT',
        'ERROR',

        COUNTIF(journal_line_count != 2),

        CASE
            WHEN COUNTIF(
                journal_line_count != 2
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every chargeback journal must contain two lines.'

    FROM (
        SELECT
            journal_id,
            COUNT(*) AS journal_line_count

        FROM
            `__PROJECT_ID__.retail_finops_mart.fct_chargeback_journal`

        GROUP BY journal_id
    )

    UNION ALL

    SELECT
        'CHARGEBACK_JOURNAL_NOT_BALANCED',
        'ERROR',

        COUNTIF(ABS(journal_total) > 0.01),

        CASE
            WHEN COUNTIF(
                ABS(journal_total) > 0.01
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every chargeback journal must net to zero.'

    FROM (
        SELECT
            journal_id,
            SUM(journal_amount)
                AS journal_total

        FROM
            `__PROJECT_ID__.retail_finops_mart.fct_chargeback_journal`

        GROUP BY journal_id
    )

    UNION ALL

    SELECT
        'CLOSE_CHECKLIST_REQUIRED_FIELD_MISSING',
        'ERROR',

        COUNTIF(
            checklist_item_id IS NULL
            OR task_id IS NULL
            OR TRIM(task_id) = ''
            OR owner IS NULL
            OR TRIM(owner) = ''
            OR due_date IS NULL
            OR status IS NULL
            OR TRIM(status) = ''
        ),

        CASE
            WHEN COUNTIF(
                checklist_item_id IS NULL
                OR task_id IS NULL
                OR TRIM(task_id) = ''
                OR owner IS NULL
                OR TRIM(owner) = ''
                OR due_date IS NULL
                OR status IS NULL
                OR TRIM(status) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Checklist rows require task, owner, due date and status.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_close_checklist`

    UNION ALL

    SELECT
        'UNSUPPORTED_CLOSE_STATUS',
        'ERROR',

        COUNTIF(
            status NOT IN (
                'COMPLETED',
                'PENDING',
                'BLOCKED'
            )
        ),

        CASE
            WHEN COUNTIF(
                status NOT IN (
                    'COMPLETED',
                    'PENDING',
                    'BLOCKED'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Only controlled close-checklist statuses are permitted.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_close_checklist`
)

SELECT
    check_name,
    severity,
    issue_count,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM quality_checks;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.monthly_close_data_quality_control`

ORDER BY
    CASE severity
        WHEN 'ERROR' THEN 1
        ELSE 2
    END,
    check_name;


SELECT
    CASE
        WHEN COUNTIF(
            severity = 'ERROR'
            AND check_status = 'FAIL'
        ) > 0
        THEN 'FAIL'

        ELSE 'PASS'
    END AS overall_monthly_close_data_quality_status,

    COUNTIF(
        severity = 'ERROR'
        AND check_status = 'FAIL'
    ) AS failed_error_checks

FROM
    `__PROJECT_ID__.retail_finops_control.monthly_close_data_quality_control`;

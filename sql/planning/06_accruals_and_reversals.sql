/*
Purpose:
    Create traceable month-end accruals for late-arriving cloud cost
    and automatic next-period reversal records.

Grain:
    Accrual:
        One row per late-arriving allocation record.

    Reversal:
        One row per accrual.

Source:
    retail_finops_core.vw_cloud_cost_allocated

Key controls:
    - Accrual retains source record and allocation lineage.
    - Reversal equals the negative accrual amount.
    - Accrual plus reversal nets to zero.
    - No late cost is silently ignored.

Owner:
    Finance.

Refresh:
    After monthly allocation refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_cloud_accrual`

PARTITION BY close_month

CLUSTER BY
    provider_name,
    application_name,
    cost_center

AS

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                allocation_id,
                '|',
                record_id,
                '|',
                CAST(
                    DATE_TRUNC(
                        DATE(charge_period_start),
                        MONTH
                    )
                    AS STRING
                ),
                '|ACCRUAL'
            )
        )
    ) AS accrual_id,

    DATE_TRUNC(
        DATE(charge_period_start),
        MONTH
    ) AS close_month,

    LAST_DAY(
        DATE(charge_period_start),
        MONTH
    ) AS accrual_posting_date,

    DATE_ADD(
        LAST_DAY(
            DATE(charge_period_start),
            MONTH
        ),
        INTERVAL 1 DAY
    ) AS expected_reversal_date,

    allocation_id,
    record_id,
    source_record_id,
    pipeline_run_id,
    source_system,
    source_file,
    ingestion_timestamp,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    target_application_name
        AS application_name,

    target_department_name
        AS department_name,

    target_environment_name
        AS environment_name,

    target_cost_center
        AS cost_center,

    target_owner_name
        AS owner_name,

    billing_currency,

    CAST(
        allocated_cost
        AS NUMERIC
    ) AS accrual_amount,

    'LATE_ARRIVING_CLOUD_COST'
        AS accrual_reason,

    'ACTUAL_LATE_ARRIVING_COST'
        AS accrual_method,

    is_synthetic,

    'POSTED'
        AS accrual_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_core.vw_cloud_cost_allocated`

WHERE is_late_arriving = TRUE;


CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_accrual_reversal`

PARTITION BY reversal_month

CLUSTER BY
    provider_name,
    application_name,
    cost_center

AS

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                accrual_id,
                '|REVERSAL'
            )
        )
    ) AS reversal_id,

    accrual_id,

    DATE_TRUNC(
        expected_reversal_date,
        MONTH
    ) AS reversal_month,

    expected_reversal_date
        AS reversal_posting_date,

    allocation_id,
    record_id,
    source_record_id,
    pipeline_run_id,
    source_system,
    source_file,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,

    billing_currency,

    CAST(
        -accrual_amount
        AS NUMERIC
    ) AS reversal_amount,

    'AUTOMATIC_NEXT_PERIOD_REVERSAL'
        AS reversal_reason,

    'POSTED'
        AS reversal_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_mart.fct_cloud_accrual`;

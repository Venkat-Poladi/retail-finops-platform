/*
Purpose:
    Validate record-level quality, lineage, financial validity and allocation
    readiness of the core cloud-cost fact table.

Expected result:
    Every check returns failure_count = 0 and check_status = PASS.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.fact_data_quality`
AS

WITH fact AS (
    SELECT *
    FROM `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
),

duplicate_record_ids AS (
    SELECT
        record_id,
        COUNT(*) AS record_count
    FROM
        fact
    GROUP BY
        record_id
    HAVING
        COUNT(*) > 1
),

checks AS (
    SELECT
        'NULL_RECORD_ID' AS check_name,
        COUNTIF(record_id IS NULL OR record_id = '') AS failure_count
    FROM fact

    UNION ALL

    SELECT
        'DUPLICATE_RECORD_ID',
        COALESCE(SUM(record_count - 1), 0)
    FROM duplicate_record_ids

    UNION ALL

    SELECT
        'NONCANONICAL_ROW_IN_FACT',
        COUNTIF(NOT is_canonical_record)
    FROM fact

    UNION ALL

    SELECT
        'INVALID_FINANCIAL_ROW_IN_FACT',
        COUNTIF(NOT is_valid_for_financial_reporting)
    FROM fact

    UNION ALL

    SELECT
        'NULL_PROVIDER_NAME',
        COUNTIF(provider_name IS NULL OR provider_name = '')
    FROM fact

    UNION ALL

    SELECT
        'INVALID_PROVIDER_NAME',
        COUNTIF(provider_name NOT IN ('AWS', 'GCP'))
    FROM fact

    UNION ALL

    SELECT
        'NULL_BILLING_ACCOUNT_ID',
        COUNTIF(billing_account_id IS NULL OR billing_account_id = '')
    FROM fact

    UNION ALL

    SELECT
        'NULL_BILLED_COST',
        COUNTIF(billed_cost IS NULL)
    FROM fact

    UNION ALL

    SELECT
        'INVALID_CHARGE_PERIOD_ORDER',
        COUNTIF(
            charge_period_start IS NULL
            OR charge_period_end IS NULL
            OR charge_period_start >= charge_period_end
        )
    FROM fact

    UNION ALL

    SELECT
        'MISSING_SOURCE_LINEAGE',
        COUNTIF(
            pipeline_run_id IS NULL
            OR pipeline_run_id = ''
            OR source_system IS NULL
            OR source_system = ''
            OR source_file IS NULL
            OR source_file = ''
            OR ingestion_timestamp IS NULL
            OR source_record_id IS NULL
            OR source_record_id = ''
        )
    FROM fact

    UNION ALL

    SELECT
        'UNSUPPORTED_BILLING_CURRENCY',
        COUNTIF(
            billing_currency IS NULL
            OR billing_currency = ''
            OR billing_currency NOT IN ('USD')
        )
    FROM fact

    UNION ALL

    SELECT
        'UNDOCUMENTED_NEGATIVE_USAGE_COST',
        COUNTIF(
            charge_category = 'Usage'
            AND billed_cost < NUMERIC '0'
            AND COALESCE(data_quality_reason, '') = ''
        )
    FROM fact

    UNION ALL

    SELECT
        'GCP_CREDIT_WITHOUT_PARENT',
        COUNTIF(
            provider_name = 'GCP'
            AND charge_category = 'Credit'
            AND (parent_record_id IS NULL OR parent_record_id = '')
        )
    FROM fact

    UNION ALL

    SELECT
        'ALLOCATED_COST_POPULATED_PREMATURELY',
        COUNTIF(allocated_cost IS NOT NULL)
    FROM fact

    UNION ALL

    SELECT
        'INVALID_DATA_STATUS',
        COUNTIF(data_status <> 'APPROVED' OR data_status IS NULL)
    FROM fact
)

SELECT
    check_name,
    CAST(failure_count AS INT64) AS failure_count,
    CASE
        WHEN failure_count = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS check_status,
    CURRENT_TIMESTAMP() AS control_timestamp
FROM
    checks;

SELECT
    check_name,
    failure_count,
    check_status
FROM
    `__PROJECT_ID__.retail_finops_control.fact_data_quality`
ORDER BY
    check_name;

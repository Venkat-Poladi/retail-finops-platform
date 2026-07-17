/*
Purpose:
    Reconcile the approved staging subset to the core cloud-cost fact table.

Pass rules:
    - Row variance must be zero.
    - Absolute billed-cost variance must be <= 0.01.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.fact_reconciliation`
AS

WITH approved_staging AS (
    SELECT
        provider_name,
        COUNT(*) AS approved_staging_rows,
        SUM(billed_cost) AS approved_staging_billed_cost
    FROM
        `__PROJECT_ID__.retail_finops_staging.vw_focus_conformed_union`
    WHERE
        is_canonical_record = TRUE
        AND is_valid_for_financial_reporting = TRUE
    GROUP BY
        provider_name
),

fact AS (
    SELECT
        provider_name,
        COUNT(*) AS fact_rows,
        SUM(billed_cost) AS fact_billed_cost
    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
    GROUP BY
        provider_name
),

provider_reconciliation AS (
    SELECT
        approved_staging.provider_name,
        approved_staging.approved_staging_rows,
        COALESCE(fact.fact_rows, 0) AS fact_rows,
        COALESCE(fact.fact_rows, 0)
            - approved_staging.approved_staging_rows AS row_variance,
        ROUND(approved_staging.approved_staging_billed_cost, 6)
            AS approved_staging_billed_cost,
        ROUND(COALESCE(fact.fact_billed_cost, NUMERIC '0'), 6)
            AS fact_billed_cost,
        ROUND(
            COALESCE(fact.fact_billed_cost, NUMERIC '0')
                - approved_staging.approved_staging_billed_cost,
            6
        ) AS cost_variance
    FROM
        approved_staging
    LEFT JOIN
        fact
    USING
        (provider_name)
),

all_cloud_reconciliation AS (
    SELECT
        'ALL_CLOUD' AS provider_name,
        SUM(approved_staging_rows) AS approved_staging_rows,
        SUM(fact_rows) AS fact_rows,
        SUM(row_variance) AS row_variance,
        ROUND(SUM(approved_staging_billed_cost), 6)
            AS approved_staging_billed_cost,
        ROUND(SUM(fact_billed_cost), 6) AS fact_billed_cost,
        ROUND(SUM(cost_variance), 6) AS cost_variance
    FROM
        provider_reconciliation
),

combined AS (
    SELECT * FROM provider_reconciliation
    UNION ALL
    SELECT * FROM all_cloud_reconciliation
)

SELECT
    provider_name,
    approved_staging_rows,
    fact_rows,
    row_variance,
    approved_staging_billed_cost,
    fact_billed_cost,
    cost_variance,
    CASE
        WHEN row_variance = 0
         AND ABS(cost_variance) <= NUMERIC '0.01'
            THEN 'PASS'
        ELSE 'FAIL'
    END AS reconciliation_status,
    CURRENT_TIMESTAMP() AS control_timestamp
FROM
    combined;

SELECT
    provider_name,
    approved_staging_rows,
    fact_rows,
    row_variance,
    approved_staging_billed_cost,
    fact_billed_cost,
    cost_variance,
    reconciliation_status
FROM
    `__PROJECT_ID__.retail_finops_control.fact_reconciliation`
ORDER BY
    CASE WHEN provider_name = 'ALL_CLOUD' THEN 2 ELSE 1 END,
    provider_name;

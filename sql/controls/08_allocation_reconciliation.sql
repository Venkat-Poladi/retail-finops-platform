/*
Purpose:
    Reconcile fact-table billed cost to allocation output.

Grain:
    One row per provider plus one all-cloud row.

Source:
    retail_finops_core.fct_cloud_cost
    retail_finops_core.fct_cost_allocation

Key controls:
    - Every fact record exists in allocation.
    - Every source record reconciles individually.
    - Provider and all-cloud variances remain within $0.01.

Owner:
    FinOps

Refresh:
    After fct_cost_allocation refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.allocation_reconciliation_control`

AS

WITH fact_by_provider AS (
    SELECT
        provider_name,

        COUNT(*) AS fact_rows,

        SUM(billed_cost)
            AS fact_billed_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`

    GROUP BY provider_name
),

allocation_by_provider AS (
    SELECT
        provider_name,

        COUNT(DISTINCT record_id)
            AS allocated_source_records,

        COUNT(*) AS allocation_rows,

        SUM(allocated_cost)
            AS allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`

    GROUP BY provider_name
),

record_reconciliation AS (
    SELECT
        provider_name,
        record_id,

        ANY_VALUE(source_billed_cost)
            AS source_billed_cost,

        SUM(allocated_cost)
            AS allocated_cost,

        SUM(allocated_cost)
            - ANY_VALUE(source_billed_cost)
            AS record_variance

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`

    GROUP BY
        provider_name,
        record_id
),

record_exceptions AS (
    SELECT
        provider_name,

        COUNTIF(
            ABS(record_variance) > 0.01
        ) AS mismatched_source_records

    FROM record_reconciliation

    GROUP BY provider_name
),

provider_control AS (
    SELECT
        fact.provider_name,

        fact.fact_rows,

        COALESCE(
            allocation.allocated_source_records,
            0
        ) AS allocated_source_records,

        COALESCE(
            allocation.allocation_rows,
            0
        ) AS allocation_rows,

        CAST(
            fact.fact_billed_cost
            AS NUMERIC
        ) AS fact_billed_cost,

        CAST(
            allocation.allocated_cost
            AS NUMERIC
        ) AS allocated_cost,

        CAST(
            allocation.allocated_cost
                - fact.fact_billed_cost
            AS NUMERIC
        ) AS allocation_variance,

        COALESCE(
            exception.mismatched_source_records,
            0
        ) AS mismatched_source_records

    FROM fact_by_provider AS fact

    LEFT JOIN allocation_by_provider AS allocation
        USING (provider_name)

    LEFT JOIN record_exceptions AS exception
        USING (provider_name)
),

all_cloud_control AS (
    SELECT
        'ALL_CLOUD' AS provider_name,

        SUM(fact_rows)
            AS fact_rows,

        SUM(allocated_source_records)
            AS allocated_source_records,

        SUM(allocation_rows)
            AS allocation_rows,

        SUM(fact_billed_cost)
            AS fact_billed_cost,

        SUM(allocated_cost)
            AS allocated_cost,

        SUM(allocated_cost)
            - SUM(fact_billed_cost)
            AS allocation_variance,

        SUM(mismatched_source_records)
            AS mismatched_source_records

    FROM provider_control
),

final_control AS (
    SELECT
        *

    FROM provider_control

    UNION ALL

    SELECT
        *

    FROM all_cloud_control
)

SELECT
    provider_name,
    fact_rows,
    allocated_source_records,
    allocation_rows,

    ROUND(fact_billed_cost, 6)
        AS fact_billed_cost,

    ROUND(allocated_cost, 6)
        AS allocated_cost,

    ROUND(allocation_variance, 6)
        AS allocation_variance,

    mismatched_source_records,

    CASE
        WHEN fact_rows = allocated_source_records
         AND ABS(allocation_variance) <= 0.01
         AND mismatched_source_records = 0
        THEN 'PASS'

        ELSE 'FAIL'
    END AS reconciliation_status,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM final_control;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.allocation_reconciliation_control`

ORDER BY
    CASE
        WHEN provider_name = 'ALL_CLOUD'
        THEN 2
        ELSE 1
    END,
    provider_name;

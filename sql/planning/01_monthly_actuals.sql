/*
Purpose:
    Create monthly allocated cloud-cost actuals.

Grain:
    One row per billing month, provider and allocated business target.

Source:
    retail_finops_core.vw_cloud_cost_allocated

Key controls:
    - Uses allocated_cost, not duplicated source billed cost.
    - Shared allocation children aggregate back to the source cost.
    - Unallocated cost remains visible.
    - Source-record counts remain available.

Owner:
    FinOps.

Refresh:
    After allocation refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`

PARTITION BY billing_month

CLUSTER BY
    provider_name,
    application_name,
    department_name,
    cost_center

AS

SELECT
    DATE_TRUNC(
        DATE(charge_period_start),
        MONTH
    ) AS billing_month,

    provider_name,

    COALESCE(
        NULLIF(TRIM(target_application_name), ''),
        'Unallocated'
    ) AS application_name,

    COALESCE(
        NULLIF(TRIM(target_department_name), ''),
        'Unallocated'
    ) AS department_name,

    COALESCE(
        NULLIF(TRIM(target_environment_name), ''),
        'Unallocated'
    ) AS environment_name,

    COALESCE(
        NULLIF(TRIM(target_cost_center), ''),
        'Unallocated'
    ) AS cost_center,

    COALESCE(
        NULLIF(TRIM(target_owner_name), ''),
        'Unallocated'
    ) AS owner_name,

    billing_currency,

    COUNT(*) AS allocation_row_count,

    COUNT(DISTINCT record_id)
        AS source_record_count,

    CAST(
        SUM(allocated_cost)
        AS NUMERIC
    ) AS actual_cost,

    CAST(
        SUM(
            CASE
                WHEN UPPER(charge_category) = 'USAGE'
                 AND allocated_cost > 0
                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS positive_usage_cost,

    CAST(
        SUM(
            CASE
                WHEN allocation_method = 'DIRECT'
                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS direct_cost,

    CAST(
        SUM(
            CASE
                WHEN allocation_method = 'SHARED_PROPORTIONAL'
                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS shared_allocated_cost,

    CAST(
        SUM(
            CASE
                WHEN allocation_method = 'UNALLOCATED'
                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS unallocated_cost,

    CAST(
        SUM(
            CASE
                WHEN is_late_arriving
                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS late_arriving_cost,

    CAST(
        SUM(
            CASE
                WHEN is_synthetic
                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS synthetic_cost,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_core.vw_cloud_cost_allocated`

GROUP BY
    billing_month,
    provider_name,
    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,
    billing_currency;

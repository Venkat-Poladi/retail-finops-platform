/*
Purpose:
    Calculate proportional allocation weights from directly attributed
    positive Usage spend.

Grain:
    One row per billing month, provider, driver scope and allocation target.

Source:
    retail_finops_core.fct_cloud_cost

Key controls:
    - Only direct positive Usage cost contributes to the driver.
    - Primary weights are calculated by provider, month and sub-account.
    - Fallback weights are calculated by provider and month.
    - Every driver group must sum to 1.

Owner:
    FinOps

Refresh:
    After fct_cloud_cost is refreshed.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_core.allocation_driver_weight`

PARTITION BY billing_month

CLUSTER BY
    provider_name,
    driver_scope,
    sub_account_id,
    target_application_name

AS

WITH classified_fact AS (
    SELECT
        DATE_TRUNC(DATE(charge_period_start), MONTH) AS billing_month,

        provider_name,
        sub_account_id,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        allocation_status,
        charge_category,
        billed_cost,

        CASE
            WHEN UPPER(TRIM(COALESCE(application_name, '')))
                    = 'SHARED PLATFORM'
              OR UPPER(TRIM(COALESCE(allocation_status, '')))
                    LIKE '%SHARED%'
            THEN 'SHARED'

            WHEN NULLIF(TRIM(application_name), '') IS NOT NULL
             AND NULLIF(TRIM(department_name), '') IS NOT NULL
             AND NULLIF(TRIM(cost_center), '') IS NOT NULL
            THEN 'DIRECT'

            ELSE 'UNALLOCATED'
        END AS source_allocation_route

    FROM `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
),

direct_positive_usage AS (
    SELECT
        billing_month,
        provider_name,
        sub_account_id,

        application_name AS target_application_name,
        department_name AS target_department_name,
        environment_name AS target_environment_name,
        cost_center AS target_cost_center,
        owner_name AS target_owner_name,

        SUM(billed_cost) AS driver_value

    FROM classified_fact

    WHERE source_allocation_route = 'DIRECT'
      AND UPPER(charge_category) = 'USAGE'
      AND billed_cost > 0

    GROUP BY
        billing_month,
        provider_name,
        sub_account_id,
        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name
),

primary_driver AS (
    SELECT
        billing_month,
        provider_name,
        sub_account_id,

        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name,

        driver_value,

        SUM(driver_value) OVER (
            PARTITION BY
                billing_month,
                provider_name,
                sub_account_id
        ) AS driver_total

    FROM direct_positive_usage
),

fallback_driver_base AS (
    SELECT
        billing_month,
        provider_name,

        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name,

        SUM(driver_value) AS driver_value

    FROM direct_positive_usage

    GROUP BY
        billing_month,
        provider_name,
        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name
),

fallback_driver AS (
    SELECT
        billing_month,
        provider_name,

        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name,

        driver_value,

        SUM(driver_value) OVER (
            PARTITION BY
                billing_month,
                provider_name
        ) AS driver_total

    FROM fallback_driver_base
),

combined_weights AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    CAST(billing_month AS STRING),
                    '|',
                    provider_name,
                    '|PRIMARY|',
                    COALESCE(sub_account_id, ''),
                    '|',
                    target_application_name,
                    '|',
                    COALESCE(target_environment_name, ''),
                    '|',
                    target_cost_center
                )
            )
        ) AS driver_weight_id,

        billing_month,
        provider_name,
        sub_account_id,

        'PRIMARY' AS driver_scope,
        'DIRECT_POSITIVE_USAGE_COST'
            AS allocation_driver,

        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name,

        CAST(driver_value AS NUMERIC)
            AS driver_value,

        CAST(driver_total AS NUMERIC)
            AS driver_total,

        CAST(
            SAFE_DIVIDE(driver_value, driver_total)
            AS NUMERIC
        ) AS allocation_weight

    FROM primary_driver

    WHERE driver_total > 0

    UNION ALL

    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    CAST(billing_month AS STRING),
                    '|',
                    provider_name,
                    '|FALLBACK|',
                    target_application_name,
                    '|',
                    COALESCE(target_environment_name, ''),
                    '|',
                    target_cost_center
                )
            )
        ),

        billing_month,
        provider_name,
        CAST(NULL AS STRING) AS sub_account_id,

        'FALLBACK',
        'DIRECT_POSITIVE_USAGE_COST',

        target_application_name,
        target_department_name,
        target_environment_name,
        target_cost_center,
        target_owner_name,

        CAST(driver_value AS NUMERIC),
        CAST(driver_total AS NUMERIC),

        CAST(
            SAFE_DIVIDE(driver_value, driver_total)
            AS NUMERIC
        )

    FROM fallback_driver

    WHERE driver_total > 0
)

SELECT
    driver_weight_id,
    billing_month,
    provider_name,
    sub_account_id,
    driver_scope,
    allocation_driver,

    target_application_name,
    target_department_name,
    target_environment_name,
    target_cost_center,
    target_owner_name,

    driver_value,
    driver_total,
    allocation_weight,

    CURRENT_TIMESTAMP() AS data_refresh_timestamp

FROM combined_weights;
/*
Purpose:
    Allocate every approved fact-table record through exactly one route:
    DIRECT, SHARED_PROPORTIONAL or UNALLOCATED.

Grain:
    One row per source record and allocation target.

Source:
    retail_finops_core.fct_cloud_cost
    retail_finops_core.allocation_driver_weight

Key controls:
    - Every fact record must create at least one allocation row.
    - Direct and unallocated records create exactly one allocation row.
    - Shared records can create multiple child rows.
    - Child allocated costs must sum to the source billed cost.
    - Credits and refunds retain their sign.
    - No source record can use more than one allocation method.

Owner:
    FinOps

Refresh:
    After allocation_driver_weight is refreshed.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`

PARTITION BY billing_month

CLUSTER BY
    provider_name,
    allocation_method,
    target_application_name,
    record_id

AS

WITH fact_records AS (
    SELECT
        record_id,
        parent_record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        DATE_TRUNC(DATE(charge_period_start), MONTH)
            AS billing_month,

        charge_period_start,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        application_name
            AS source_application_name,

        department_name
            AS source_department_name,

        environment_name
            AS source_environment_name,

        cost_center
            AS source_cost_center,

        owner_name
            AS source_owner_name,

        allocation_status
            AS source_allocation_status,

        charge_category,
        billed_cost,
        billing_currency

    FROM `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
),

classified_records AS (
    SELECT
        fact_records.*,

        CASE
            WHEN UPPER(
                    TRIM(
                        COALESCE(
                            source_application_name,
                            ''
                        )
                    )
                 ) = 'SHARED PLATFORM'

              OR UPPER(
                    TRIM(
                        COALESCE(
                            source_allocation_status,
                            ''
                        )
                    )
                 ) LIKE '%SHARED%'

            THEN 'SHARED'

            WHEN NULLIF(
                    TRIM(source_application_name),
                    ''
                 ) IS NOT NULL

             AND NULLIF(
                    TRIM(source_department_name),
                    ''
                 ) IS NOT NULL

             AND NULLIF(
                    TRIM(source_cost_center),
                    ''
                 ) IS NOT NULL

            THEN 'DIRECT'

            ELSE 'UNALLOCATED'
        END AS source_allocation_route

    FROM fact_records
),

direct_allocations AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    record_id,
                    '|DIRECT|',
                    source_application_name,
                    '|',
                    source_cost_center
                )
            )
        ) AS allocation_id,

        record_id,
        parent_record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        billing_month,
        charge_period_start,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        source_application_name,
        source_department_name,
        source_environment_name,
        source_cost_center,
        source_owner_name,

        source_application_name
            AS target_application_name,

        source_department_name
            AS target_department_name,

        source_environment_name
            AS target_environment_name,

        source_cost_center
            AS target_cost_center,

        source_owner_name
            AS target_owner_name,

        'DIRECT' AS allocation_method,

        'SOURCE_BUSINESS_ATTRIBUTION'
            AS allocation_driver,

        'SOURCE' AS driver_scope,

        CAST(NULL AS NUMERIC)
            AS driver_value,

        CAST(NULL AS NUMERIC)
            AS driver_total,

        CAST(1 AS NUMERIC)
            AS allocation_weight,

        CAST(billed_cost AS NUMERIC)
            AS source_billed_cost,

        CAST(billed_cost AS NUMERIC)
            AS allocated_cost,

        billing_currency,

        TRUE AS is_allocated,

        'ALLOCATED' AS allocation_status,

        'DIRECT_SOURCE_ATTRIBUTION'
            AS allocation_rule_id,

        CURRENT_TIMESTAMP()
            AS data_refresh_timestamp

    FROM classified_records

    WHERE source_allocation_route = 'DIRECT'
),

shared_records AS (
    SELECT
        *

    FROM classified_records

    WHERE source_allocation_route = 'SHARED'
),

shared_scope AS (
    SELECT
        shared_records.*,

        EXISTS (
            SELECT
                1

            FROM
                `__PROJECT_ID__.retail_finops_core.allocation_driver_weight`
                    AS weight

            WHERE weight.driver_scope = 'PRIMARY'
              AND weight.billing_month
                    = shared_records.billing_month
              AND weight.provider_name
                    = shared_records.provider_name
              AND COALESCE(weight.sub_account_id, '')
                    = COALESCE(
                        shared_records.sub_account_id,
                        ''
                    )
        ) AS has_primary_driver,

        EXISTS (
            SELECT
                1

            FROM
                `__PROJECT_ID__.retail_finops_core.allocation_driver_weight`
                    AS weight

            WHERE weight.driver_scope = 'FALLBACK'
              AND weight.billing_month
                    = shared_records.billing_month
              AND weight.provider_name
                    = shared_records.provider_name
        ) AS has_fallback_driver

    FROM shared_records
),

shared_allocations AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    shared_scope.record_id,
                    '|SHARED_PROPORTIONAL|',
                    weight.driver_scope,
                    '|',
                    weight.target_application_name,
                    '|',
                    COALESCE(
                        weight.target_environment_name,
                        ''
                    ),
                    '|',
                    weight.target_cost_center
                )
            )
        ) AS allocation_id,

        shared_scope.record_id,
        shared_scope.parent_record_id,
        shared_scope.source_record_id,
        shared_scope.pipeline_run_id,
        shared_scope.source_system,
        shared_scope.source_file,

        shared_scope.billing_month,
        shared_scope.charge_period_start,

        shared_scope.provider_name,
        shared_scope.billing_account_id,
        shared_scope.sub_account_id,
        shared_scope.project_id,

        shared_scope.source_application_name,
        shared_scope.source_department_name,
        shared_scope.source_environment_name,
        shared_scope.source_cost_center,
        shared_scope.source_owner_name,

        weight.target_application_name,
        weight.target_department_name,
        weight.target_environment_name,
        weight.target_cost_center,
        weight.target_owner_name,

        'SHARED_PROPORTIONAL'
            AS allocation_method,

        weight.allocation_driver,
        weight.driver_scope,
        weight.driver_value,
        weight.driver_total,
        weight.allocation_weight,

        CAST(shared_scope.billed_cost AS NUMERIC)
            AS source_billed_cost,

        CAST(
            shared_scope.billed_cost
                * weight.allocation_weight
            AS NUMERIC
        ) AS allocated_cost,

        shared_scope.billing_currency,

        TRUE AS is_allocated,

        'ALLOCATED' AS allocation_status,

        CASE
            WHEN weight.driver_scope = 'PRIMARY'
            THEN 'SHARED_PRIMARY_POSITIVE_USAGE'

            ELSE 'SHARED_FALLBACK_POSITIVE_USAGE'
        END AS allocation_rule_id,

        CURRENT_TIMESTAMP()
            AS data_refresh_timestamp

    FROM shared_scope

    INNER JOIN
        `__PROJECT_ID__.retail_finops_core.allocation_driver_weight`
            AS weight

        ON weight.billing_month
            = shared_scope.billing_month

       AND weight.provider_name
            = shared_scope.provider_name

       AND (
            (
                shared_scope.has_primary_driver
                AND weight.driver_scope = 'PRIMARY'
                AND COALESCE(weight.sub_account_id, '')
                    = COALESCE(
                        shared_scope.sub_account_id,
                        ''
                    )
            )

            OR

            (
                NOT shared_scope.has_primary_driver
                AND shared_scope.has_fallback_driver
                AND weight.driver_scope = 'FALLBACK'
            )
       )
),

shared_without_driver AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    record_id,
                    '|UNALLOCATED|SHARED_NO_DRIVER'
                )
            )
        ) AS allocation_id,

        record_id,
        parent_record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        billing_month,
        charge_period_start,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        source_application_name,
        source_department_name,
        source_environment_name,
        source_cost_center,
        source_owner_name,

        'Unallocated'
            AS target_application_name,

        'Unallocated'
            AS target_department_name,

        'Unallocated'
            AS target_environment_name,

        'Unallocated'
            AS target_cost_center,

        'Unallocated'
            AS target_owner_name,

        'UNALLOCATED'
            AS allocation_method,

        'NO_ELIGIBLE_USAGE_DRIVER'
            AS allocation_driver,

        'NONE'
            AS driver_scope,

        CAST(NULL AS NUMERIC)
            AS driver_value,

        CAST(NULL AS NUMERIC)
            AS driver_total,

        CAST(1 AS NUMERIC)
            AS allocation_weight,

        CAST(billed_cost AS NUMERIC)
            AS source_billed_cost,

        CAST(billed_cost AS NUMERIC)
            AS allocated_cost,

        billing_currency,

        FALSE AS is_allocated,

        'UNALLOCATED'
            AS allocation_status,

        'SHARED_NO_DRIVER'
            AS allocation_rule_id,

        CURRENT_TIMESTAMP()
            AS data_refresh_timestamp

    FROM shared_scope

    WHERE NOT has_primary_driver
      AND NOT has_fallback_driver
),

source_unallocated AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    record_id,
                    '|UNALLOCATED|SOURCE_UNOWNED'
                )
            )
        ) AS allocation_id,

        record_id,
        parent_record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        billing_month,
        charge_period_start,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        source_application_name,
        source_department_name,
        source_environment_name,
        source_cost_center,
        source_owner_name,

        'Unallocated'
            AS target_application_name,

        'Unallocated'
            AS target_department_name,

        'Unallocated'
            AS target_environment_name,

        'Unallocated'
            AS target_cost_center,

        'Unallocated'
            AS target_owner_name,

        'UNALLOCATED'
            AS allocation_method,

        'MISSING_BUSINESS_ATTRIBUTION'
            AS allocation_driver,

        'NONE'
            AS driver_scope,

        CAST(NULL AS NUMERIC)
            AS driver_value,

        CAST(NULL AS NUMERIC)
            AS driver_total,

        CAST(1 AS NUMERIC)
            AS allocation_weight,

        CAST(billed_cost AS NUMERIC)
            AS source_billed_cost,

        CAST(billed_cost AS NUMERIC)
            AS allocated_cost,

        billing_currency,

        FALSE AS is_allocated,

        'UNALLOCATED'
            AS allocation_status,

        'SOURCE_MISSING_ATTRIBUTION'
            AS allocation_rule_id,

        CURRENT_TIMESTAMP()
            AS data_refresh_timestamp

    FROM classified_records

    WHERE source_allocation_route = 'UNALLOCATED'
)

SELECT
    *

FROM direct_allocations

UNION ALL

SELECT
    *

FROM shared_allocations

UNION ALL

SELECT
    *

FROM shared_without_driver

UNION ALL

SELECT
    *

FROM source_unallocated;
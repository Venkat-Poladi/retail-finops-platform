/*
Purpose:
    Create the monthly allocated-cost base for unit economics.

Grain:
    One row per billing month, provider and allocated application.

Source:
    retail_finops_core.fct_cost_allocation

Key controls:
    - Uses allocated_cost, not repeated source billed cost.
    - Shared costs remain assigned to their allocation targets.
    - Unallocated cost remains visible.
    - Production and non-production costs remain separately measurable.
    - Provider totals reconcile to the allocation fact.

Owner:
    FinOps Analytics.

Refresh:
    After the allocation pipeline refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_unit_economics_cost_base`

PARTITION BY billing_month

CLUSTER BY
    provider_name,
    application_name,
    department_name,
    cost_center

AS

SELECT
    billing_month,
    provider_name,

    COALESCE(
        NULLIF(
            TRIM(target_application_name),
            ''
        ),
        'Unallocated'
    ) AS application_name,

    COALESCE(
        NULLIF(
            TRIM(target_department_name),
            ''
        ),
        'Unallocated'
    ) AS department_name,

    COALESCE(
        NULLIF(
            TRIM(target_cost_center),
            ''
        ),
        'Unallocated'
    ) AS cost_center,

    COALESCE(
        NULLIF(
            TRIM(target_owner_name),
            ''
        ),
        'FinOps Lead'
    ) AS owner_name,

    billing_currency,

    COUNT(*)
        AS allocation_row_count,

    COUNT(DISTINCT record_id)
        AS source_record_count,

    CAST(
        SUM(allocated_cost)
        AS NUMERIC
    ) AS total_allocated_cost,

    CAST(
        SUM(
            CASE
                WHEN LOWER(
                    COALESCE(
                        target_environment_name,
                        ''
                    )
                ) = 'prod'

                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS production_cost,

    CAST(
        SUM(
            CASE
                WHEN LOWER(
                    COALESCE(
                        target_environment_name,
                        ''
                    )
                ) = 'nonprod'

                THEN allocated_cost
                ELSE 0
            END
        )
        AS NUMERIC
    ) AS nonproduction_cost,

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
                WHEN allocation_method
                    = 'SHARED_PROPORTIONAL'

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

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`

GROUP BY
    billing_month,
    provider_name,
    application_name,
    department_name,
    cost_center,
    owner_name,
    billing_currency;

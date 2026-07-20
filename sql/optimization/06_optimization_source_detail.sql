/*
Purpose:
    Link every optimization recommendation to its contributing fact records.

Grain:
    One row per recommendation and contributing fact record.

Source:
    mart_optimization
    fct_cloud_cost

Key controls:
    - Every recommendation baseline traces to source records.
    - Baseline contribution is normalized by the number of months.
    - Commitment coverage eligible cost uses only on-demand usage.
    - Commitment utilization uses underutilized commitment records.
    - Complete pipeline lineage remains available.

Owner:
    FinOps Analytics.

Refresh:
    After mart_optimization refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.optimization_source_detail`

CLUSTER BY
    recommendation_id,
    provider_name,
    record_id

AS

WITH resource_recommendation_detail AS (
    SELECT
        optimization.recommendation_id,
        optimization.rule_id,

        optimization.baseline_population_type,
        optimization.baseline_start_date,
        optimization.baseline_end_date,
        optimization.baseline_month_count,

        fact.record_id,
        fact.parent_record_id,
        fact.source_record_id,
        fact.pipeline_run_id,
        fact.source_system,
        fact.source_file,
        fact.ingestion_timestamp,

        fact.provider_name,
        fact.billing_account_id,
        fact.sub_account_id,
        fact.project_id,

        COALESCE(
            NULLIF(TRIM(fact.application_name), ''),
            'Unallocated'
        ) AS application_name,

        COALESCE(
            NULLIF(TRIM(fact.department_name), ''),
            'Unallocated'
        ) AS department_name,

        COALESCE(
            NULLIF(TRIM(fact.environment_name), ''),
            'Unallocated'
        ) AS environment_name,

        COALESCE(
            NULLIF(TRIM(fact.cost_center), ''),
            'Unallocated'
        ) AS cost_center,

        COALESCE(
            NULLIF(TRIM(fact.owner_name), ''),
            'FinOps Lead'
        ) AS owner_name,

        fact.service_category,
        fact.service_name,

        COALESCE(
            NULLIF(TRIM(fact.resource_id), ''),
            'UNKNOWN_RESOURCE'
        ) AS resource_id,

        COALESCE(
            NULLIF(TRIM(fact.resource_name), ''),
            'Unknown Resource'
        ) AS resource_name,

        COALESCE(
            NULLIF(TRIM(fact.region_name), ''),
            'global'
        ) AS region_name,

        fact.charge_category,
        fact.pricing_category,

        fact.commitment_discount_id,
        fact.commitment_discount_type,
        fact.commitment_discount_status,

        fact.effective_cost,

        CAST(
            SAFE_DIVIDE(
                fact.effective_cost,
                optimization.baseline_month_count
            )
            AS NUMERIC
        ) AS baseline_contribution_cost,

        CAST(
            CASE
                WHEN optimization.rule_id
                        = 'COMMITMENT_COVERAGE'

                 AND NOT (
                    fact.pricing_category
                        = 'Commitment Discount'

                    OR fact.commitment_discount_id
                        IS NOT NULL
                 )

                THEN SAFE_DIVIDE(
                    fact.effective_cost,
                    optimization.baseline_month_count
                )

                WHEN optimization.rule_id
                        <> 'COMMITMENT_COVERAGE'

                THEN SAFE_DIVIDE(
                    fact.effective_cost,
                    optimization.baseline_month_count
                )

                ELSE 0
            END
            AS NUMERIC
        ) AS eligible_contribution_cost,

        fact.billing_currency,
        fact.is_synthetic,
        fact.is_late_arriving,
        fact.data_status

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
            AS optimization

    INNER JOIN
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
            AS fact

        ON fact.provider_name
            = optimization.provider_name

       AND COALESCE(
            NULLIF(TRIM(fact.billing_account_id), ''),
            'UNKNOWN_BILLING_ACCOUNT'
           )
            = optimization.billing_account_id

       AND COALESCE(
            NULLIF(TRIM(fact.sub_account_id), ''),
            'UNKNOWN_SUB_ACCOUNT'
           )
            = optimization.sub_account_id

       AND COALESCE(
            NULLIF(TRIM(fact.project_id), ''),
            'NOT_APPLICABLE'
           )
            = optimization.project_id

       AND COALESCE(
            NULLIF(TRIM(fact.application_name), ''),
            'Unallocated'
           )
            = optimization.application_name

       AND COALESCE(
            NULLIF(TRIM(fact.department_name), ''),
            'Unallocated'
           )
            = optimization.department_name

       AND COALESCE(
            NULLIF(TRIM(fact.environment_name), ''),
            'Unallocated'
           )
            = optimization.environment_name

       AND COALESCE(
            NULLIF(TRIM(fact.cost_center), ''),
            'Unallocated'
           )
            = optimization.cost_center

       AND COALESCE(
            NULLIF(TRIM(fact.owner_name), ''),
            'FinOps Lead'
           )
            = optimization.owner

       AND COALESCE(
            NULLIF(TRIM(fact.service_name), ''),
            'Unknown Service'
           )
            = optimization.service_name

       AND COALESCE(
            NULLIF(TRIM(fact.resource_id), ''),
            'UNKNOWN_RESOURCE'
           )
            = optimization.resource_id

       AND COALESCE(
            NULLIF(TRIM(fact.region_name), ''),
            'global'
           )
            = optimization.region_name

       AND fact.billing_currency
            = optimization.billing_currency

       AND DATE(fact.charge_period_start)
            >= optimization.baseline_start_date

       AND DATE(fact.charge_period_start)
            < optimization.baseline_end_date

    WHERE optimization.baseline_population_type
            = 'RESOURCE_POSITIVE_USAGE'

      AND UPPER(fact.charge_category) = 'USAGE'

      AND fact.effective_cost > 0
),

commitment_recommendation_detail AS (
    SELECT
        optimization.recommendation_id,
        optimization.rule_id,

        optimization.baseline_population_type,
        optimization.baseline_start_date,
        optimization.baseline_end_date,
        optimization.baseline_month_count,

        fact.record_id,
        fact.parent_record_id,
        fact.source_record_id,
        fact.pipeline_run_id,
        fact.source_system,
        fact.source_file,
        fact.ingestion_timestamp,

        fact.provider_name,
        fact.billing_account_id,
        fact.sub_account_id,
        fact.project_id,

        COALESCE(
            NULLIF(TRIM(fact.application_name), ''),
            'Unallocated'
        ) AS application_name,

        COALESCE(
            NULLIF(TRIM(fact.department_name), ''),
            'Unallocated'
        ) AS department_name,

        COALESCE(
            NULLIF(TRIM(fact.environment_name), ''),
            'Unallocated'
        ) AS environment_name,

        COALESCE(
            NULLIF(TRIM(fact.cost_center), ''),
            'Unallocated'
        ) AS cost_center,

        COALESCE(
            NULLIF(TRIM(fact.owner_name), ''),
            'FinOps Lead'
        ) AS owner_name,

        fact.service_category,
        fact.service_name,

        COALESCE(
            NULLIF(TRIM(fact.resource_id), ''),
            'UNKNOWN_RESOURCE'
        ) AS resource_id,

        COALESCE(
            NULLIF(TRIM(fact.resource_name), ''),
            'Unknown Resource'
        ) AS resource_name,

        COALESCE(
            NULLIF(TRIM(fact.region_name), ''),
            'global'
        ) AS region_name,

        fact.charge_category,
        fact.pricing_category,

        fact.commitment_discount_id,
        fact.commitment_discount_type,
        fact.commitment_discount_status,

        fact.effective_cost,

        CAST(
            SAFE_DIVIDE(
                fact.effective_cost,
                optimization.baseline_month_count
            )
            AS NUMERIC
        ) AS baseline_contribution_cost,

        CAST(
            SAFE_DIVIDE(
                fact.effective_cost,
                optimization.baseline_month_count
            )
            AS NUMERIC
        ) AS eligible_contribution_cost,

        fact.billing_currency,
        fact.is_synthetic,
        fact.is_late_arriving,
        fact.data_status

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
            AS optimization

    INNER JOIN
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
            AS fact

        ON fact.provider_name
            = optimization.provider_name

       AND COALESCE(
            NULLIF(TRIM(fact.billing_account_id), ''),
            'UNKNOWN_BILLING_ACCOUNT'
           )
            = optimization.billing_account_id

       AND COALESCE(
            NULLIF(TRIM(fact.sub_account_id), ''),
            'UNKNOWN_SUB_ACCOUNT'
           )
            = optimization.sub_account_id

       AND COALESCE(
            NULLIF(TRIM(fact.project_id), ''),
            'NOT_APPLICABLE'
           )
            = optimization.project_id

       AND COALESCE(
            NULLIF(TRIM(fact.application_name), ''),
            'Unallocated'
           )
            = optimization.application_name

       AND COALESCE(
            NULLIF(TRIM(fact.department_name), ''),
            'Unallocated'
           )
            = optimization.department_name

       AND COALESCE(
            NULLIF(TRIM(fact.environment_name), ''),
            'Unallocated'
           )
            = optimization.environment_name

       AND COALESCE(
            NULLIF(TRIM(fact.cost_center), ''),
            'Unallocated'
           )
            = optimization.cost_center

       AND COALESCE(
            NULLIF(TRIM(fact.owner_name), ''),
            'FinOps Lead'
           )
            = optimization.owner

       AND fact.billing_currency
            = optimization.billing_currency

       AND DATE(fact.charge_period_start)
            >= optimization.baseline_start_date

       AND DATE(fact.charge_period_start)
            < optimization.baseline_end_date

    WHERE optimization.baseline_population_type
            = 'COMMITMENT_UNUSED_COST'

      AND fact.commitment_discount_status
            = 'Underutilized'

      AND fact.effective_cost > 0
)

SELECT
    *,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM resource_recommendation_detail

UNION ALL

SELECT
    *,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM commitment_recommendation_detail;

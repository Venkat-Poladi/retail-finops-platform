/*
Purpose:
    Create the traceable resource-level cost baseline used for optimization.

Grain:
    One row per provider, billing hierarchy, business owner, service,
    resource, region and currency.

Source:
    retail_finops_core.fct_cloud_cost

Key controls:
    - Uses the latest three complete billing months.
    - Uses positive Usage effective cost.
    - Credits, refunds, taxes and purchases do not inflate usage baselines.
    - On-demand and commitment-covered cost remain separately measurable.
    - Every baseline retains contributing source-record counts.

Owner:
    FinOps Analytics.

Refresh:
    After fct_cloud_cost refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_optimization_resource_baseline`

CLUSTER BY
    provider_name,
    application_name,
    service_category,
    service_name

AS

WITH source_max_date AS (
    SELECT
        MAX(
            DATE(charge_period_start)
        ) AS maximum_charge_date

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
),

complete_month_boundary AS (
    SELECT
        maximum_charge_date,

        CASE
            WHEN maximum_charge_date
                    = LAST_DAY(maximum_charge_date)
            THEN DATE_TRUNC(
                maximum_charge_date,
                MONTH
            )

            ELSE DATE_SUB(
                DATE_TRUNC(
                    maximum_charge_date,
                    MONTH
                ),
                INTERVAL 1 MONTH
            )
        END AS latest_complete_month_start

    FROM source_max_date
),

baseline_window AS (
    SELECT
        maximum_charge_date,

        DATE_SUB(
            latest_complete_month_start,
            INTERVAL 2 MONTH
        ) AS baseline_start_date,

        DATE_ADD(
            latest_complete_month_start,
            INTERVAL 1 MONTH
        ) AS baseline_end_date,

        DATE_ADD(
            latest_complete_month_start,
            INTERVAL 1 MONTH
        ) AS analysis_date

    FROM complete_month_boundary
),

normalized_usage AS (
    SELECT
        fact.record_id,

        DATE(fact.charge_period_start)
            AS charge_date,

        DATE_TRUNC(
            DATE(fact.charge_period_start),
            MONTH
        ) AS charge_month,

        fact.provider_name,

        COALESCE(
            NULLIF(TRIM(fact.billing_account_id), ''),
            'UNKNOWN_BILLING_ACCOUNT'
        ) AS billing_account_id,

        COALESCE(
            NULLIF(TRIM(fact.sub_account_id), ''),
            'UNKNOWN_SUB_ACCOUNT'
        ) AS sub_account_id,

        COALESCE(
            NULLIF(TRIM(fact.project_id), ''),
            'NOT_APPLICABLE'
        ) AS project_id,

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

        COALESCE(
            NULLIF(TRIM(fact.service_category), ''),
            'Other'
        ) AS service_category,

        COALESCE(
            NULLIF(TRIM(fact.service_name), ''),
            'Unknown Service'
        ) AS service_name,

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

        fact.billing_currency,

        COALESCE(
            fact.list_cost,
            NUMERIC '0'
        ) AS list_cost,

        COALESCE(
            fact.effective_cost,
            NUMERIC '0'
        ) AS effective_cost,

        fact.pricing_category,
        fact.commitment_discount_id,
        fact.commitment_discount_type,
        fact.commitment_discount_status,

        fact.is_synthetic,

        baseline_dates.baseline_start_date,
        baseline_dates.baseline_end_date,
        baseline_dates.analysis_date

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
            AS fact

    CROSS JOIN baseline_window AS baseline_dates

    WHERE DATE(fact.charge_period_start)
            >= baseline_dates.baseline_start_date

      AND DATE(fact.charge_period_start)
            < baseline_dates.baseline_end_date

      AND UPPER(fact.charge_category) = 'USAGE'

      AND COALESCE(
            fact.effective_cost,
            NUMERIC '0'
          ) > 0
),

aggregated_baseline AS (
    SELECT
        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        service_category,
        service_name,
        resource_id,
        resource_name,
        region_name,

        billing_currency,

        baseline_start_date,
        baseline_end_date,
        analysis_date,

        COUNT(
            DISTINCT charge_month
        ) AS baseline_month_count,

        COUNT(*)
            AS source_row_count,

        COUNT(
            DISTINCT record_id
        ) AS source_record_count,

        LOGICAL_AND(is_synthetic)
            AS is_synthetic_baseline,

        CAST(
            SUM(list_cost)
            AS NUMERIC
        ) AS baseline_total_list_cost,

        CAST(
            SUM(effective_cost)
            AS NUMERIC
        ) AS baseline_total_effective_cost,

        CAST(
            SUM(
                CASE
                    WHEN pricing_category
                            = 'Commitment Discount'
                      OR commitment_discount_id IS NOT NULL

                    THEN effective_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS baseline_commitment_covered_cost,

        CAST(
            SUM(
                CASE
                    WHEN NOT (
                        pricing_category
                            = 'Commitment Discount'
                        OR commitment_discount_id IS NOT NULL
                    )

                    THEN effective_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS baseline_on_demand_cost,

        STRING_AGG(
            DISTINCT commitment_discount_type,
            ', '
            ORDER BY commitment_discount_type
        ) AS commitment_discount_types,

        STRING_AGG(
            DISTINCT commitment_discount_status,
            ', '
            ORDER BY commitment_discount_status
        ) AS commitment_discount_statuses

    FROM normalized_usage

    GROUP BY
        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        service_category,
        service_name,
        resource_id,
        resource_name,
        region_name,
        billing_currency,
        baseline_start_date,
        baseline_end_date,
        analysis_date
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                provider_name,
                '|',
                billing_account_id,
                '|',
                sub_account_id,
                '|',
                project_id,
                '|',
                application_name,
                '|',
                department_name,
                '|',
                environment_name,
                '|',
                cost_center,
                '|',
                owner_name,
                '|',
                service_name,
                '|',
                resource_id,
                '|',
                region_name,
                '|',
                billing_currency
            )
        )
    ) AS resource_cost_key,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,

    service_category,
    service_name,
    resource_id,
    resource_name,
    region_name,

    billing_currency,

    baseline_start_date,
    baseline_end_date,
    analysis_date,
    baseline_month_count,

    source_row_count,
    source_record_count,
    is_synthetic_baseline,

    baseline_total_list_cost,
    baseline_total_effective_cost,

    CAST(
        SAFE_DIVIDE(
            baseline_total_list_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_list_cost,

    CAST(
        SAFE_DIVIDE(
            baseline_total_effective_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_baseline_cost,

    CAST(
        SAFE_DIVIDE(
            baseline_commitment_covered_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_commitment_covered_cost,

    CAST(
        SAFE_DIVIDE(
            baseline_on_demand_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_on_demand_cost,

    CAST(
        SAFE_DIVIDE(
            baseline_commitment_covered_cost,

            baseline_commitment_covered_cost
                + baseline_on_demand_cost
        )
        AS NUMERIC
    ) AS commitment_coverage_pct,

    CAST(
        SAFE_DIVIDE(
            baseline_total_list_cost
                - baseline_total_effective_cost,

            baseline_total_list_cost
        )
        AS NUMERIC
    ) AS effective_discount_pct,

    commitment_discount_types,
    commitment_discount_statuses,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM aggregated_baseline;

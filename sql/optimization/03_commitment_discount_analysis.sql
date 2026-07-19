/*
Purpose:
    Analyze modeled AWS and GCP commitment-discount coverage and utilization.

Grain:
    One row per provider, billing hierarchy, business owner and currency.

Source:
    retail_finops_core.fct_cloud_cost

Key controls:
    - Coverage measures eligible usage protected by commitments.
    - Utilization measures purchased commitment value being consumed.
    - On-demand and covered costs remain separate.
    - AWS and GCP provider mechanics remain distinguishable.
    - Uses the same three-month baseline window as optimization.

Owner:
    FinOps Analytics.

Refresh:
    After fct_cloud_cost refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_commitment_discount_analysis`

CLUSTER BY
    provider_name,
    application_name,
    environment_name

AS

WITH baseline_window AS (
    SELECT
        MIN(baseline_start_date)
            AS baseline_start_date,

        MAX(baseline_end_date)
            AS baseline_end_date,

        MAX(analysis_date)
            AS analysis_date

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization_resource_baseline`
),

normalized_fact AS (
    SELECT
        fact.record_id,

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

        fact.charge_category,
        fact.pricing_category,

        fact.commitment_discount_id,
        fact.commitment_discount_type,
        fact.commitment_discount_status,

        COALESCE(
            fact.billed_cost,
            NUMERIC '0'
        ) AS billed_cost,

        COALESCE(
            fact.effective_cost,
            NUMERIC '0'
        ) AS effective_cost,

        fact.billing_currency,

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
),

portfolio_cost AS (
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

        billing_currency,

        baseline_start_date,
        baseline_end_date,
        analysis_date,

        COUNT(
            DISTINCT charge_month
        ) AS baseline_month_count,

        COUNT(
            DISTINCT record_id
        ) AS source_record_count,

        CAST(
            SUM(
                CASE
                    WHEN UPPER(charge_category) = 'USAGE'
                     AND service_category IN (
                            'Compute',
                            'Serverless'
                         )
                     AND effective_cost > 0

                    THEN effective_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS eligible_usage_cost,

        CAST(
            SUM(
                CASE
                    WHEN UPPER(charge_category) = 'USAGE'
                     AND service_category IN (
                            'Compute',
                            'Serverless'
                         )
                     AND effective_cost > 0
                     AND (
                            pricing_category
                                = 'Commitment Discount'
                            OR commitment_discount_id IS NOT NULL
                         )

                    THEN effective_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS covered_usage_cost,

        CAST(
            SUM(
                CASE
                    WHEN UPPER(charge_category) = 'USAGE'
                     AND service_category IN (
                            'Compute',
                            'Serverless'
                         )
                     AND effective_cost > 0
                     AND NOT (
                            pricing_category
                                = 'Commitment Discount'
                            OR commitment_discount_id IS NOT NULL
                         )

                    THEN effective_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS on_demand_usage_cost,

        CAST(
            SUM(
                CASE
                    WHEN UPPER(charge_category) = 'PURCHASE'
                     AND billed_cost > 0

                    THEN billed_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS commitment_purchase_cost,

        CAST(
            SUM(
                CASE
                    WHEN commitment_discount_status
                            = 'Underutilized'
                     AND effective_cost > 0

                    THEN effective_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS underutilized_commitment_cost,

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

    FROM normalized_fact

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
                billing_currency,
                '|COMMITMENT_PORTFOLIO'
            )
        )
    ) AS commitment_portfolio_key,

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

    baseline_start_date,
    baseline_end_date,
    analysis_date,
    baseline_month_count,
    source_record_count,

    CAST(
        SAFE_DIVIDE(
            eligible_usage_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_commitment_eligible_cost,

    CAST(
        SAFE_DIVIDE(
            covered_usage_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_commitment_covered_cost,

    CAST(
        SAFE_DIVIDE(
            on_demand_usage_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_on_demand_cost,

    CAST(
        SAFE_DIVIDE(
            commitment_purchase_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_commitment_purchase_cost,

    CAST(
        SAFE_DIVIDE(
            underutilized_commitment_cost,
            baseline_month_count
        )
        AS NUMERIC
    ) AS monthly_underutilized_commitment_cost,

    CAST(
        SAFE_DIVIDE(
            covered_usage_cost,
            eligible_usage_cost
        )
        AS NUMERIC
    ) AS commitment_coverage_pct,

    CAST(
        LEAST(
            NUMERIC '1',
            GREATEST(
                NUMERIC '0',

                NUMERIC '1'
                    - SAFE_DIVIDE(
                        underutilized_commitment_cost,
                        NULLIF(
                            commitment_purchase_cost,
                            NUMERIC '0'
                        )
                    )
            )
        )
        AS NUMERIC
    ) AS commitment_utilization_pct,

    commitment_discount_types,
    commitment_discount_statuses,

    CASE
        WHEN provider_name = 'AWS'
        THEN 'Savings Plans and Reserved Instances'

        WHEN provider_name = 'GCP'
        THEN 'Committed Use Discounts'

        ELSE 'Commitment Discounts'
    END AS provider_commitment_program,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM portfolio_cost

WHERE eligible_usage_cost > 0
   OR commitment_purchase_cost > 0
   OR underutilized_commitment_cost > 0;

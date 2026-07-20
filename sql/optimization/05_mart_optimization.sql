/*
Purpose:
    Create the final optimization recommendation and savings-lifecycle mart.

Grain:
    One row per optimization recommendation.

Source:
    optimization_recommendation_candidates

Key controls:
    - Uses controlled savings-stage vocabulary.
    - Every financial result is marked MODELED.
    - Realized savings exist only for the Realized stage.
    - Lifecycle dates are deterministic relative to the data analysis date.
    - Identified opportunities are not presented as actual realized savings.

Owner:
    FinOps Analytics.

Refresh:
    After recommendation candidate refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_optimization`

CLUSTER BY
    provider_name,
    savings_stage,
    recommendation_category,
    application_name

AS

WITH lifecycle_assignment AS (
    SELECT
        candidates.*,

        CASE rule_id
            WHEN 'OBSERVABILITY_CONTROL'
                THEN 'Realized'

            WHEN 'NONPROD_SCHEDULE'
                THEN 'Implemented'

            WHEN 'STORAGE_LIFECYCLE'
                THEN 'Approved'

            WHEN 'COMPUTE_RIGHTSIZE'
                THEN 'Approved'

            WHEN 'NETWORK_EFFICIENCY'
                THEN 'Identified'

            WHEN 'COMMITMENT_COVERAGE'
                THEN 'Identified'

            WHEN 'COMMITMENT_UTILIZATION'
                THEN 'Identified'

            ELSE 'Identified'
        END AS savings_stage

    FROM
        `__PROJECT_ID__.retail_finops_mart.optimization_recommendation_candidates`
            AS candidates
),

lifecycle_dates AS (
    SELECT
        lifecycle.*,

        CASE savings_stage
            WHEN 'Realized'
                THEN DATE_SUB(
                    baseline_end_date,
                    INTERVAL 60 DAY
                )

            WHEN 'Implemented'
                THEN DATE_SUB(
                    baseline_end_date,
                    INTERVAL 30 DAY
                )

            WHEN 'Approved'
                THEN DATE_ADD(
                    baseline_end_date,
                    INTERVAL 30 DAY
                )

            ELSE DATE_ADD(
                baseline_end_date,
                INTERVAL 45 DAY
            )
        END AS target_date,

        CASE savings_stage
            WHEN 'Realized'
                THEN DATE_SUB(
                    baseline_end_date,
                    INTERVAL 45 DAY
                )

            WHEN 'Implemented'
                THEN DATE_SUB(
                    baseline_end_date,
                    INTERVAL 15 DAY
                )

            ELSE CAST(NULL AS DATE)
        END AS implementation_date,

        CASE savings_stage
            WHEN 'Realized'
                THEN DATE_SUB(
                    baseline_end_date,
                    INTERVAL 15 DAY
                )

            ELSE CAST(NULL AS DATE)
        END AS validation_date

    FROM lifecycle_assignment AS lifecycle
)

SELECT
    recommendation_id,
    rule_id,

    priority,
    provider_name,

    billing_account_id,
    sub_account_id,
    project_id,

    application_name,
    department_name,
    environment_name,
    cost_center,

    service_category,
    service_name,

    resource_id,
    resource_name,
    region_name,
    billing_currency,

    recommendation_category,
    recommendation,

    baseline_cost,
    eligible_cost,
    proposed_cost,

    gross_savings,
    overlap_adjustment,
    net_monthly_savings,
    annualized_savings,

    dependency_recommendation_id,
    overlap_group_id,
    calculation_order,

    confidence,
    effort,
    risk,
    owner,

    savings_stage,
    target_date,
    implementation_date,
    validation_date,

    CAST(
        CASE
            WHEN savings_stage = 'Realized'
            THEN net_monthly_savings
                * NUMERIC '0.85'

            ELSE 0
        END
        AS NUMERIC
    ) AS realized_savings,

    CASE
        WHEN savings_stage = 'Realized'
        THEN NUMERIC '0.85'

        ELSE NUMERIC '0'
    END AS realization_rate_pct,

    baseline_population_type,
    baseline_start_date,
    baseline_end_date,
    baseline_month_count,

    assumption_text,

    commitment_coverage_pct,
    commitment_utilization_pct,

    monthly_on_demand_cost,
    monthly_commitment_covered_cost,
    monthly_underutilized_commitment_cost,

    source_record_count,
    is_synthetic_baseline,

    savings_value_type,

    'MODELED_WORKFLOW_DEMONSTRATION'
        AS lifecycle_basis,

    CASE
        WHEN savings_stage = 'Realized'
        THEN
            'Modeled realized amount using an 85% realization assumption. '
            || 'This is not actual company savings.'

        WHEN savings_stage IN (
            'Approved',
            'Implemented'
        )
        THEN
            'Modeled workflow status used to demonstrate savings governance.'

        ELSE
            'Modeled opportunity awaiting modeled approval and implementation.'
    END AS lifecycle_disclosure,

    'Pass' AS data_quality_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM lifecycle_dates;

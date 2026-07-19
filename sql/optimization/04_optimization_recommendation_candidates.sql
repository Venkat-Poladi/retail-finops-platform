/*
Purpose:
    Generate traceable modeled optimization recommendation candidates.

Grain:
    One row per optimization recommendation.

Source:
    mart_optimization_resource_baseline
    mart_commitment_discount_analysis
    optimization_rule_catalog

Key controls:
    - Every recommendation has a traceable baseline.
    - Gross, overlap and net savings remain separate.
    - Commitment coverage follows compute rightsizing.
    - Non-production compute scheduling follows compute rightsizing.
    - Only net savings enter portfolio totals.
    - Savings remain explicitly modeled.

Owner:
    FinOps Analytics.

Refresh:
    After baseline and commitment analysis refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.optimization_recommendation_candidates`

CLUSTER BY
    provider_name,
    recommendation_category,
    application_name,
    service_category

AS

WITH rules AS (
    SELECT
        rule_id,
        recommendation_category,
        modeled_reduction_pct,
        minimum_monthly_cost,
        maximum_coverage_pct,
        minimum_utilization_pct,
        priority,
        confidence,
        effort,
        risk,
        calculation_order,
        baseline_population_type,
        assumption_text

    FROM
        `__PROJECT_ID__.retail_finops_control.optimization_rule_catalog`

    WHERE is_enabled
),

resource_context AS (
    SELECT
        baseline.resource_cost_key
            AS context_key,

        'RESOURCE' AS context_type,

        baseline.provider_name,
        baseline.billing_account_id,
        baseline.sub_account_id,
        baseline.project_id,

        baseline.application_name,
        baseline.department_name,
        baseline.environment_name,
        baseline.cost_center,
        baseline.owner_name,

        baseline.service_category,
        baseline.service_name,
        baseline.resource_id,
        baseline.resource_name,
        baseline.region_name,

        baseline.billing_currency,

        baseline.baseline_start_date,
        baseline.baseline_end_date,
        baseline.analysis_date,
        baseline.baseline_month_count,

        baseline.source_record_count,
        baseline.is_synthetic_baseline,

        baseline.monthly_baseline_cost,
        baseline.monthly_on_demand_cost,
        baseline.monthly_commitment_covered_cost,
        baseline.commitment_coverage_pct,

        commitment.commitment_utilization_pct,
        commitment.monthly_underutilized_commitment_cost,

        commitment.provider_commitment_program

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization_resource_baseline`
            AS baseline

    LEFT JOIN
        `__PROJECT_ID__.retail_finops_mart.mart_commitment_discount_analysis`
            AS commitment

        ON commitment.provider_name
            = baseline.provider_name

       AND commitment.billing_account_id
            = baseline.billing_account_id

       AND commitment.sub_account_id
            = baseline.sub_account_id

       AND commitment.project_id
            = baseline.project_id

       AND commitment.application_name
            = baseline.application_name

       AND commitment.department_name
            = baseline.department_name

       AND commitment.environment_name
            = baseline.environment_name

       AND commitment.cost_center
            = baseline.cost_center

       AND commitment.owner_name
            = baseline.owner_name

       AND commitment.billing_currency
            = baseline.billing_currency
),

commitment_context AS (
    SELECT
        commitment_portfolio_key
            AS context_key,

        'COMMITMENT_PORTFOLIO'
            AS context_type,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        'Commitment' AS service_category,

        provider_commitment_program
            AS service_name,

        CONCAT(
            'COMMITMENT-',
            commitment_portfolio_key
        ) AS resource_id,

        CONCAT(
            application_name,
            ' ',
            provider_commitment_program
        ) AS resource_name,

        'global' AS region_name,

        billing_currency,

        baseline_start_date,
        baseline_end_date,
        analysis_date,
        baseline_month_count,

        source_record_count,

        TRUE AS is_synthetic_baseline,

        monthly_underutilized_commitment_cost
            AS monthly_baseline_cost,

        monthly_on_demand_cost,

        monthly_commitment_covered_cost,

        commitment_coverage_pct,
        commitment_utilization_pct,
        monthly_underutilized_commitment_cost,

        provider_commitment_program

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_commitment_discount_analysis`

    WHERE monthly_underutilized_commitment_cost > 0
),

eligible_resource_rules AS (
    SELECT
        context.*,
        rule.*

    FROM resource_context AS context

    INNER JOIN rules AS rule

        ON (
            rule.rule_id = 'COMPUTE_RIGHTSIZE'

            AND context.service_category = 'Compute'

            AND context.monthly_baseline_cost
                    >= rule.minimum_monthly_cost
        )

        OR (
            rule.rule_id = 'NONPROD_SCHEDULE'

            AND LOWER(context.environment_name)
                    = 'nonprod'

            AND context.service_category IN (
                'Compute',
                'Database'
            )

            AND (
                (
                    context.service_category = 'Compute'
                    AND context.monthly_baseline_cost
                            >= NUMERIC '100'
                )

                OR (
                    context.service_category = 'Database'
                    AND context.monthly_baseline_cost
                            >= rule.minimum_monthly_cost
                )
            )
        )

        OR (
            rule.rule_id = 'OBSERVABILITY_CONTROL'

            AND context.service_category
                    = 'Observability'

            AND context.monthly_baseline_cost
                    >= rule.minimum_monthly_cost
        )

        OR (
            rule.rule_id = 'STORAGE_LIFECYCLE'

            AND context.service_category = 'Storage'

            AND context.monthly_baseline_cost
                    >= rule.minimum_monthly_cost
        )

        OR (
            rule.rule_id = 'NETWORK_EFFICIENCY'

            AND context.service_category = 'Network'

            AND context.monthly_baseline_cost
                    >= rule.minimum_monthly_cost
        )

        OR (
            rule.rule_id = 'COMMITMENT_COVERAGE'

            AND LOWER(context.environment_name)
                    = 'prod'

            AND context.service_category = 'Compute'

            AND context.monthly_baseline_cost
                    >= rule.minimum_monthly_cost

            AND context.monthly_on_demand_cost
                    >= NUMERIC '50'

            AND COALESCE(
                    context.commitment_coverage_pct,
                    NUMERIC '0'
                ) < rule.maximum_coverage_pct

            AND (
                context.commitment_utilization_pct IS NULL

                OR context.commitment_utilization_pct
                    >= rule.minimum_utilization_pct
            )
        )
),

eligible_commitment_rules AS (
    SELECT
        context.*,
        rule.*

    FROM commitment_context AS context

    INNER JOIN rules AS rule
        ON rule.rule_id
            = 'COMMITMENT_UTILIZATION'

    WHERE context.monthly_baseline_cost
            >= rule.minimum_monthly_cost

      AND COALESCE(
            context.commitment_utilization_pct,
            NUMERIC '0'
          ) < rule.maximum_coverage_pct
),

eligible_candidates AS (
    SELECT
        *

    FROM eligible_resource_rules

    UNION ALL

    SELECT
        *

    FROM eligible_commitment_rules
),

candidate_dependencies AS (
    SELECT
        candidates.*,

        (
            SELECT modeled_reduction_pct

            FROM rules

            WHERE rule_id = 'COMPUTE_RIGHTSIZE'
        ) AS compute_rightsize_pct,

        TO_HEX(
            SHA256(
                CONCAT(
                    context_key,
                    '|',
                    rule_id
                )
            )
        ) AS recommendation_id,

        CASE
            WHEN rule_id = 'COMMITMENT_COVERAGE'
            THEN TO_HEX(
                SHA256(
                    CONCAT(
                        context_key,
                        '|COMPUTE_RIGHTSIZE'
                    )
                )
            )

            WHEN rule_id = 'NONPROD_SCHEDULE'
             AND service_category = 'Compute'
            THEN TO_HEX(
                SHA256(
                    CONCAT(
                        context_key,
                        '|COMPUTE_RIGHTSIZE'
                    )
                )
            )

            ELSE CAST(NULL AS STRING)
        END AS dependency_recommendation_id,

        context_key AS overlap_group_id

    FROM eligible_candidates AS candidates
),

gross_savings_calculation AS (
    SELECT
        dependencies.*,

        CAST(
            CASE
                WHEN rule_id = 'COMMITMENT_COVERAGE'
                THEN monthly_on_demand_cost
                    * modeled_reduction_pct

                ELSE monthly_baseline_cost
                    * modeled_reduction_pct
            END
            AS NUMERIC
        ) AS gross_savings,

        CAST(
            CASE
                WHEN rule_id = 'COMMITMENT_COVERAGE'
                THEN monthly_on_demand_cost

                ELSE monthly_baseline_cost
            END
            AS NUMERIC
        ) AS eligible_cost

    FROM candidate_dependencies AS dependencies
),

overlap_calculation AS (
    SELECT
        gross.*,

        CAST(
            CASE
                WHEN dependency_recommendation_id IS NOT NULL
                THEN gross_savings
                    * compute_rightsize_pct

                ELSE 0
            END
            AS NUMERIC
        ) AS overlap_adjustment,

        CASE
            WHEN dependency_recommendation_id IS NOT NULL
            THEN 2

            ELSE 1
        END AS final_calculation_order

    FROM gross_savings_calculation AS gross
),

net_savings_calculation AS (
    SELECT
        overlap.*,

        CAST(
            gross_savings
                - overlap_adjustment
            AS NUMERIC
        ) AS net_monthly_savings,

        CAST(
            CASE
                WHEN dependency_recommendation_id IS NOT NULL
                THEN monthly_baseline_cost
                    - (
                        monthly_baseline_cost
                            * compute_rightsize_pct
                    )
                    - (
                        gross_savings
                            - overlap_adjustment
                    )

                ELSE monthly_baseline_cost
                    - (
                        gross_savings
                            - overlap_adjustment
                    )
            END
            AS NUMERIC
        ) AS proposed_cost

    FROM overlap_calculation AS overlap
)

SELECT
    recommendation_id,
    rule_id,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    application_name,
    department_name,
    environment_name,
    cost_center,

    owner_name AS owner,

    service_category,
    service_name,
    resource_id,
    resource_name,
    region_name,

    billing_currency,

    baseline_population_type,

    baseline_start_date,
    baseline_end_date,
    baseline_month_count,

    monthly_baseline_cost
        AS baseline_cost,

    eligible_cost,

    GREATEST(
        NUMERIC '0',
        proposed_cost
    ) AS proposed_cost,

    gross_savings,
    overlap_adjustment,
    net_monthly_savings,

    CAST(
        net_monthly_savings * 12
        AS NUMERIC
    ) AS annualized_savings,

    dependency_recommendation_id,
    overlap_group_id,
    final_calculation_order
        AS calculation_order,

    recommendation_category,

    CASE rule_id
        WHEN 'COMPUTE_RIGHTSIZE'
        THEN
            'Review '
            || resource_name
            || ' for compute rightsizing. Validate CPU, memory, network '
            || 'and availability requirements before changing capacity.'

        WHEN 'NONPROD_SCHEDULE'
        THEN
            'Schedule '
            || resource_name
            || ' around required non-production operating windows and '
            || 'automatically stop it when not needed.'

        WHEN 'OBSERVABILITY_CONTROL'
        THEN
            'Review log volume, retention, debug telemetry and monitoring '
            || 'sources for '
            || resource_name
            || '.'

        WHEN 'STORAGE_LIFECYCLE'
        THEN
            'Apply lifecycle, retention, deletion and storage-tier controls '
            || 'to '
            || resource_name
            || '.'

        WHEN 'NETWORK_EFFICIENCY'
        THEN
            'Review NAT, egress, cross-zone, cross-region and routing cost '
            || 'for '
            || resource_name
            || '.'

        WHEN 'COMMITMENT_COVERAGE'
        THEN
            CASE
                WHEN provider_name = 'AWS'
                THEN
                    'After usage optimization, review stable remaining demand '
                    || 'for Savings Plans or Reserved Instance coverage.'

                WHEN provider_name = 'GCP'
                THEN
                    'After usage optimization, review stable remaining demand '
                    || 'for Committed Use Discount coverage.'

                ELSE
                    'After usage optimization, review stable remaining demand '
                    || 'for commitment-discount coverage.'
            END

        WHEN 'COMMITMENT_UTILIZATION'
        THEN
            CASE
                WHEN provider_name = 'AWS'
                THEN
                    'Review underutilized Savings Plans and Reserved Instances '
                    || 'before purchasing additional commitments.'

                WHEN provider_name = 'GCP'
                THEN
                    'Review underutilized Committed Use Discounts before '
                    || 'purchasing additional commitments.'

                ELSE
                    'Review underutilized commitment discounts before '
                    || 'purchasing additional commitments.'
            END

        ELSE 'Review the identified optimization opportunity.'
    END AS recommendation,

    CASE
        WHEN rule_id = 'COMMITMENT_UTILIZATION'
         AND commitment_utilization_pct < NUMERIC '0.70'
        THEN 'High'

        ELSE priority
    END AS priority,

    confidence,
    effort,
    risk,

    CONCAT(
        assumption_text,

        CASE
            WHEN rule_id IN (
                'COMMITMENT_COVERAGE',
                'COMMITMENT_UTILIZATION'
            )
            THEN CONCAT(
                ' Current modeled coverage: ',
                COALESCE(
                    FORMAT(
                        '%.1f%%',
                        CAST(
                            commitment_coverage_pct * 100
                            AS FLOAT64
                        )
                    ),
                    'not available'
                ),
                '. Current modeled utilization: ',
                COALESCE(
                    FORMAT(
                        '%.1f%%',
                        CAST(
                            commitment_utilization_pct * 100
                            AS FLOAT64
                        )
                    ),
                    'not available'
                ),
                '.'
            )

            ELSE ''
        END
    ) AS assumption_text,

    commitment_coverage_pct,
    commitment_utilization_pct,

    monthly_on_demand_cost,
    monthly_commitment_covered_cost,
    monthly_underutilized_commitment_cost,

    source_record_count,
    is_synthetic_baseline,

    'MODELED' AS savings_value_type,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM net_savings_calculation

WHERE net_monthly_savings > 0;

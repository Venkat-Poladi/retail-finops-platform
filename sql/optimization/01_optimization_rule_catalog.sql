/*
Purpose:
    Create the controlled catalog of modeled cloud-cost optimization rules.

Grain:
    One row per optimization rule.

Source:
    Documented Retail Co. FinOps optimization assumptions.

Key controls:
    - Every rule has a documented financial assumption.
    - Modeled reductions are separated from actual realized savings.
    - Commitment coverage and commitment utilization remain separate.
    - Rules do not claim access to CPU, memory or application telemetry.

Owner:
    FinOps Analytics.

Refresh:
    Updated only after documented methodology review.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.optimization_rule_catalog`

AS

SELECT
    *

FROM UNNEST(
    [
        STRUCT(
            'COMPUTE_RIGHTSIZE' AS rule_id,
            'Rightsizing' AS recommendation_category,
            'ALL' AS provider_scope,
            'Compute' AS service_category_scope,
            'ALL' AS environment_scope,
            'RESOURCE_POSITIVE_USAGE' AS baseline_population_type,
            NUMERIC '0.15' AS modeled_reduction_pct,
            NUMERIC '100' AS minimum_monthly_cost,
            CAST(NULL AS NUMERIC) AS maximum_coverage_pct,
            CAST(NULL AS NUMERIC) AS minimum_utilization_pct,
            'High' AS priority,
            'Medium' AS confidence,
            'Medium' AS effort,
            'Medium' AS risk,
            1 AS calculation_order,
            'Review persistent compute cost for possible rightsizing. '
                || 'The 15% reduction is modeled and must be validated with '
                || 'provider utilization telemetry before implementation.'
                AS assumption_text,
            TRUE AS is_enabled
        ),

        STRUCT(
            'NONPROD_SCHEDULE',
            'Non-Production Scheduling',
            'ALL',
            'Compute or Database',
            'nonprod',
            'RESOURCE_POSITIVE_USAGE',
            NUMERIC '0.35',
            NUMERIC '75',
            CAST(NULL AS NUMERIC),
            CAST(NULL AS NUMERIC),
            'High',
            'Medium',
            'Low',
            'Low',
            2,
            'Model a 35% reduction from stopping eligible non-production '
                || 'resources outside required operating windows. Validate '
                || 'availability, batch windows and engineering requirements.',
            TRUE
        ),

        STRUCT(
            'OBSERVABILITY_CONTROL',
            'Logging and Monitoring',
            'ALL',
            'Observability',
            'ALL',
            'RESOURCE_POSITIVE_USAGE',
            NUMERIC '0.20',
            NUMERIC '50',
            CAST(NULL AS NUMERIC),
            CAST(NULL AS NUMERIC),
            'Medium',
            'High',
            'Low',
            'Low',
            1,
            'Model a 20% reduction from log-volume controls, retention review, '
                || 'sampling and removal of unnecessary debug telemetry.',
            TRUE
        ),

        STRUCT(
            'STORAGE_LIFECYCLE',
            'Storage Lifecycle',
            'ALL',
            'Storage',
            'ALL',
            'RESOURCE_POSITIVE_USAGE',
            NUMERIC '0.18',
            NUMERIC '50',
            CAST(NULL AS NUMERIC),
            CAST(NULL AS NUMERIC),
            'Medium',
            'Medium',
            'Medium',
            'Low',
            1,
            'Model an 18% reduction from lifecycle policies, deletion of '
                || 'unneeded data, storage-tier review and snapshot controls.',
            TRUE
        ),

        STRUCT(
            'NETWORK_EFFICIENCY',
            'Network Architecture',
            'ALL',
            'Network',
            'ALL',
            'RESOURCE_POSITIVE_USAGE',
            NUMERIC '0.15',
            NUMERIC '50',
            CAST(NULL AS NUMERIC),
            CAST(NULL AS NUMERIC),
            'Medium',
            'Medium',
            'High',
            'Medium',
            1,
            'Model a 15% reduction from reviewing NAT processing, egress, '
                || 'cross-zone traffic, cross-region traffic and routing.',
            TRUE
        ),

        STRUCT(
            'COMMITMENT_COVERAGE',
            'Commitment Coverage',
            'ALL',
            'Compute',
            'prod',
            'RESOURCE_POSITIVE_USAGE',
            NUMERIC '0.18',
            NUMERIC '100',
            NUMERIC '0.80',
            NUMERIC '0.75',
            'High',
            'Medium',
            'Medium',
            'Medium',
            2,
            'Model an 18% rate reduction on eligible on-demand compute cost '
                || 'after usage optimization. Purchase decisions require '
                || 'stable demand and acceptable commitment utilization.',
            TRUE
        ),

        STRUCT(
            'COMMITMENT_UTILIZATION',
            'Commitment Utilization',
            'ALL',
            'Commitment Portfolio',
            'ALL',
            'COMMITMENT_UNUSED_COST',
            NUMERIC '0.50',
            NUMERIC '25',
            NUMERIC '0.90',
            CAST(NULL AS NUMERIC),
            'High',
            'High',
            'Medium',
            'Low',
            1,
            'Model recovery of 50% of identified unused commitment cost through '
                || 'portfolio rebalancing, exchange, expiry planning or reduced '
                || 'future purchases. Provider contract rules must be reviewed.',
            TRUE
        )
    ]
);


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.optimization_rule_catalog`

ORDER BY
    calculation_order,
    rule_id;

/*
Purpose:
    Validate optimization recommendation completeness and financial logic.

Grain:
    One row per optimization data-quality check.

Source:
    mart_optimization
    optimization_source_detail
    mart_commitment_discount_analysis

Key controls:
    - Recommendation IDs are unique.
    - Required business fields are populated.
    - Financial calculations are valid.
    - Controlled vocabularies are enforced.
    - Modeled savings are clearly labeled.
    - Recommendations retain source traceability.

Owner:
    FinOps Analytics.

Refresh:
    After optimization reconciliation.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.optimization_data_quality_control`

AS

WITH optimization AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_optimization`
),

source_detail_ids AS (
    SELECT DISTINCT
        recommendation_id

    FROM
        `__PROJECT_ID__.retail_finops_mart.optimization_source_detail`
),

quality_checks AS (
    SELECT
        'NULL_RECOMMENDATION_ID'
            AS check_name,

        'ERROR' AS severity,

        COUNTIF(
            recommendation_id IS NULL
            OR TRIM(recommendation_id) = ''
        ) AS issue_count,

        CASE
            WHEN COUNTIF(
                recommendation_id IS NULL
                OR TRIM(recommendation_id) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Every recommendation requires recommendation_id.'
            AS check_description

    FROM optimization

    UNION ALL

    SELECT
        'DUPLICATE_RECOMMENDATION_ID',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'recommendation_id must be unique.'

    FROM (
        SELECT
            recommendation_id

        FROM optimization

        GROUP BY recommendation_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'MISSING_REQUIRED_BUSINESS_FIELD',
        'ERROR',

        COUNTIF(
            provider_name IS NULL
            OR TRIM(provider_name) = ''
            OR application_name IS NULL
            OR TRIM(application_name) = ''
            OR resource_name IS NULL
            OR TRIM(resource_name) = ''
            OR recommendation_category IS NULL
            OR TRIM(recommendation_category) = ''
            OR recommendation IS NULL
            OR TRIM(recommendation) = ''
            OR owner IS NULL
            OR TRIM(owner) = ''
        ),

        CASE
            WHEN COUNTIF(
                provider_name IS NULL
                OR TRIM(provider_name) = ''
                OR application_name IS NULL
                OR TRIM(application_name) = ''
                OR resource_name IS NULL
                OR TRIM(resource_name) = ''
                OR recommendation_category IS NULL
                OR TRIM(recommendation_category) = ''
                OR recommendation IS NULL
                OR TRIM(recommendation) = ''
                OR owner IS NULL
                OR TRIM(owner) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Recommendations require provider, application, resource, action and owner.'

    FROM optimization

    UNION ALL

    SELECT
        'INVALID_FINANCIAL_AMOUNT',
        'ERROR',

        COUNTIF(
            baseline_cost <= 0
            OR eligible_cost <= 0
            OR proposed_cost < 0
            OR gross_savings < 0
            OR overlap_adjustment < 0
            OR net_monthly_savings <= 0
            OR annualized_savings <= 0
        ),

        CASE
            WHEN COUNTIF(
                baseline_cost <= 0
                OR eligible_cost <= 0
                OR proposed_cost < 0
                OR gross_savings < 0
                OR overlap_adjustment < 0
                OR net_monthly_savings <= 0
                OR annualized_savings <= 0
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Optimization financial amounts must be positive and internally valid.'

    FROM optimization

    UNION ALL

    SELECT
        'ANNUALIZED_SAVINGS_MISMATCH',
        'ERROR',

        COUNTIF(
            ABS(
                annualized_savings
                    - net_monthly_savings * 12
            ) > NUMERIC '0.01'
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    annualized_savings
                        - net_monthly_savings * 12
                ) > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Annualized savings must equal net monthly savings multiplied by 12.'

    FROM optimization

    UNION ALL

    SELECT
        'INVALID_SAVINGS_STAGE',
        'ERROR',

        COUNTIF(
            savings_stage NOT IN (
                'Identified',
                'Approved',
                'Implemented',
                'Realized',
                'Rejected',
                'On Hold'
            )
        ),

        CASE
            WHEN COUNTIF(
                savings_stage NOT IN (
                    'Identified',
                    'Approved',
                    'Implemented',
                    'Realized',
                    'Rejected',
                    'On Hold'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Savings stages must use controlled vocabulary.'

    FROM optimization

    UNION ALL

    SELECT
        'INVALID_CONFIDENCE',
        'ERROR',

        COUNTIF(
            confidence NOT IN (
                'High',
                'Medium',
                'Low'
            )
        ),

        CASE
            WHEN COUNTIF(
                confidence NOT IN (
                    'High',
                    'Medium',
                    'Low'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Confidence must use High, Medium or Low.'

    FROM optimization

    UNION ALL

    SELECT
        'MISSING_ASSUMPTION',
        'ERROR',

        COUNTIF(
            assumption_text IS NULL
            OR TRIM(assumption_text) = ''
        ),

        CASE
            WHEN COUNTIF(
                assumption_text IS NULL
                OR TRIM(assumption_text) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every recommendation requires a transparent assumption.'

    FROM optimization

    UNION ALL

    SELECT
        'UNLABELED_MODELED_SAVINGS',
        'ERROR',

        COUNTIF(
            savings_value_type <> 'MODELED'
            OR lifecycle_basis
                <> 'MODELED_WORKFLOW_DEMONSTRATION'
        ),

        CASE
            WHEN COUNTIF(
                savings_value_type <> 'MODELED'
                OR lifecycle_basis
                    <> 'MODELED_WORKFLOW_DEMONSTRATION'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every result must remain clearly labeled as modeled.'

    FROM optimization

    UNION ALL

    SELECT
        'REALIZED_SAVINGS_EXCEEDS_NET_SAVINGS',
        'ERROR',

        COUNTIF(
            realized_savings
                > net_monthly_savings
        ),

        CASE
            WHEN COUNTIF(
                realized_savings
                    > net_monthly_savings
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Realized savings cannot exceed net modeled opportunity.'

    FROM optimization

    UNION ALL

    SELECT
        'NONREALIZED_STAGE_WITH_REALIZED_SAVINGS',
        'ERROR',

        COUNTIF(
            savings_stage <> 'Realized'
            AND realized_savings <> 0
        ),

        CASE
            WHEN COUNTIF(
                savings_stage <> 'Realized'
                AND realized_savings <> 0
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Only Realized-stage recommendations may carry realized savings.'

    FROM optimization

    UNION ALL

    SELECT
        'RECOMMENDATION_WITHOUT_SOURCE_DETAIL',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every recommendation must trace to source fact records.'

    FROM optimization AS recommendation

    LEFT JOIN source_detail_ids AS detail
        USING (recommendation_id)

    WHERE detail.recommendation_id IS NULL

    UNION ALL

    SELECT
        'MISSING_COMMITMENT_ANALYSIS',
        'ERROR',

        CASE
            WHEN COUNT(*) > 0
            THEN 0
            ELSE 1
        END,

        CASE
            WHEN COUNT(*) > 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'The portfolio must include commitment coverage or utilization recommendations.'

    FROM optimization

    WHERE recommendation_category IN (
        'Commitment Coverage',
        'Commitment Utilization'
    )

    UNION ALL

    SELECT
        'COMMITMENT_ANALYSIS_PROVIDER_COVERAGE',
        'ERROR',

        GREATEST(
            2 - COUNT(DISTINCT provider_name),
            0
        ),

        CASE
            WHEN COUNT(DISTINCT provider_name) = 2
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Commitment analysis must cover AWS and GCP.'

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_commitment_discount_analysis`
)

SELECT
    check_name,
    severity,
    issue_count,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM quality_checks;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.optimization_data_quality_control`

ORDER BY check_name;


SELECT
    CASE
        WHEN COUNTIF(
            severity = 'ERROR'
            AND check_status = 'FAIL'
        ) > 0
        THEN 'FAIL'

        ELSE 'PASS'
    END AS overall_optimization_data_quality_status,

    COUNTIF(
        severity = 'ERROR'
        AND check_status = 'FAIL'
    ) AS failed_error_checks

FROM
    `__PROJECT_ID__.retail_finops_control.optimization_data_quality_control`;

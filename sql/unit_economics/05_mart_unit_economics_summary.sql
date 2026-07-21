/*
Purpose:
    Create executive portfolio-level unit economics.

Grain:
    One row per month and provider, including ALL_CLOUD.

Source:
    retail_finops_mart.mart_unit_economics

Key controls:
    - Complete provider cost enters the numerator.
    - Production business activity enters the denominator.
    - Shared Platform and Unallocated activity do not inflate business units.
    - Unallocated cost remains included in total infrastructure cost.
    - Total-cost and unit-cost directions remain separate.

Owner:
    FinOps Analytics.

Refresh:
    After mart_unit_economics refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_unit_economics_summary`

PARTITION BY unit_economics_month

CLUSTER BY
    provider_name,
    financial_status

AS

WITH monthly_provider_metrics AS (
    SELECT
        unit_economics_month,
        provider_name,
        billing_currency,

        CAST(
            SUM(total_allocated_cost)
            AS NUMERIC
        ) AS total_allocated_cost,

        CAST(
            SUM(production_cost)
            AS NUMERIC
        ) AS production_cost,

        CAST(
            SUM(nonproduction_cost)
            AS NUMERIC
        ) AS nonproduction_cost,

        CAST(
            SUM(unallocated_cost)
            AS NUMERIC
        ) AS unallocated_cost,

        CAST(
            SUM(
                CASE
                    WHEN application_name NOT IN (
                        'Shared Platform',
                        'Unallocated'
                    )
                    AND has_business_activity

                    THEN transactions
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS transactions,

        CAST(
            SUM(
                CASE
                    WHEN application_name NOT IN (
                        'Shared Platform',
                        'Unallocated'
                    )
                    AND has_business_activity

                    THEN api_requests
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS api_requests,

        CAST(
            SUM(
                CASE
                    WHEN application_name NOT IN (
                        'Shared Platform',
                        'Unallocated'
                    )
                    AND has_business_activity

                    THEN average_daily_active_customers
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS average_daily_active_customers,

        CAST(
            SUM(
                CASE
                    WHEN application_name NOT IN (
                        'Shared Platform',
                        'Unallocated'
                    )
                    AND has_business_activity

                    THEN revenue
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS revenue,

        COUNTIF(has_business_activity)
            AS matched_application_count,

        COUNTIF(NOT has_business_activity)
            AS unmatched_application_count

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics`

    GROUP BY
        unit_economics_month,
        provider_name,
        billing_currency
),

unit_metrics AS (
    SELECT
        *,

        CAST(
            SAFE_DIVIDE(
                total_allocated_cost,
                transactions
            )
            AS NUMERIC
        ) AS cost_per_transaction,

        CAST(
            SAFE_DIVIDE(
                total_allocated_cost,
                average_daily_active_customers
            )
            AS NUMERIC
        ) AS cost_per_active_customer,

        CAST(
            SAFE_DIVIDE(
                total_allocated_cost,
                api_requests
            )
            AS NUMERIC
        ) AS cost_per_api_request,

        CAST(
            SAFE_DIVIDE(
                total_allocated_cost,
                revenue
            )
            AS NUMERIC
        ) AS infrastructure_cost_pct_of_revenue

    FROM monthly_provider_metrics
),

metrics_with_prior AS (
    SELECT
        unit_metrics.*,

        LAG(total_allocated_cost) OVER (
            PARTITION BY
                provider_name,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_total_allocated_cost,

        LAG(transactions) OVER (
            PARTITION BY
                provider_name,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_transactions,

        LAG(cost_per_transaction) OVER (
            PARTITION BY
                provider_name,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_cost_per_transaction

    FROM unit_metrics
),

final_metrics AS (
    SELECT
        *,

        CAST(
            SAFE_DIVIDE(
                total_allocated_cost
                    - prior_total_allocated_cost,

                ABS(prior_total_allocated_cost)
            )
            AS NUMERIC
        ) AS total_cost_change_pct,

        CAST(
            SAFE_DIVIDE(
                transactions
                    - prior_transactions,

                ABS(prior_transactions)
            )
            AS NUMERIC
        ) AS transaction_change_pct,

        CAST(
            SAFE_DIVIDE(
                cost_per_transaction
                    - prior_cost_per_transaction,

                ABS(prior_cost_per_transaction)
            )
            AS NUMERIC
        ) AS cost_per_transaction_change_pct

    FROM metrics_with_prior
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                CAST(
                    unit_economics_month
                    AS STRING
                ),
                '|',
                provider_name,
                '|',
                billing_currency,
                '|PORTFOLIO_UNIT_ECONOMICS'
            )
        )
    ) AS unit_economics_summary_id,

    unit_economics_month,
    provider_name,
    billing_currency,

    total_allocated_cost,
    production_cost,
    nonproduction_cost,
    unallocated_cost,

    transactions,
    average_daily_active_customers,
    api_requests,
    revenue,

    cost_per_transaction,
    cost_per_active_customer,
    cost_per_api_request,
    infrastructure_cost_pct_of_revenue,

    prior_total_allocated_cost,
    prior_transactions,
    prior_cost_per_transaction,

    total_cost_change_pct,
    transaction_change_pct,
    cost_per_transaction_change_pct,

    matched_application_count,
    unmatched_application_count,

    CASE
        WHEN prior_cost_per_transaction IS NULL
        THEN 'No Baseline'

        WHEN cost_per_transaction_change_pct
                <= NUMERIC '-0.05'
        THEN 'Favorable'

        WHEN ABS(
            cost_per_transaction_change_pct
        ) <= NUMERIC '0.05'
        THEN 'On Plan'

        WHEN cost_per_transaction_change_pct
                <= NUMERIC '0.10'
        THEN 'Watch'

        WHEN cost_per_transaction_change_pct
                <= NUMERIC '0.20'
        THEN 'Unfavorable'

        ELSE 'Critical'
    END AS financial_status,

    CASE
        WHEN prior_cost_per_transaction IS NULL
        THEN
            'No prior-period baseline.'

        WHEN total_cost_change_pct > 0
         AND transaction_change_pct > 0
         AND cost_per_transaction_change_pct < 0
        THEN
            'Total spend increased, but transaction growth was faster. '
            || 'Portfolio unit economics improved.'

        WHEN total_cost_change_pct > 0
         AND cost_per_transaction_change_pct > 0
        THEN
            'Total spend and cost per transaction both increased. '
            || 'Portfolio efficiency deteriorated.'

        WHEN total_cost_change_pct < 0
         AND cost_per_transaction_change_pct < 0
        THEN
            'Total spend and unit cost both improved.'

        WHEN total_cost_change_pct < 0
         AND cost_per_transaction_change_pct > 0
        THEN
            'Spend declined, but demand declined faster. Unit economics worsened.'

        ELSE
            'Review cost growth and demand growth together.'
    END AS executive_interpretation,

    'MODELED_SYNTHETIC_BUSINESS_ACTIVITY'
        AS business_activity_disclosure,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM final_metrics;

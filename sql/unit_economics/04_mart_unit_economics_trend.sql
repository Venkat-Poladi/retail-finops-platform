/*
Purpose:
    Calculate month-over-month unit-economics changes and interpretations.

Grain:
    One row per month, provider and application.

Source:
    retail_finops_mart.mart_unit_economics

Key controls:
    - Previous-month metrics use the same grain.
    - Cost and demand changes remain separate.
    - Unit-cost direction determines efficiency interpretation.
    - No-baseline periods remain explicitly labeled.

Owner:
    FinOps Analytics.

Refresh:
    After mart_unit_economics refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_unit_economics_trend`

PARTITION BY unit_economics_month

CLUSTER BY
    provider_name,
    application_name,
    financial_status

AS

WITH metrics_with_prior AS (
    SELECT
        unit_economics.*,

        LAG(total_allocated_cost) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_total_allocated_cost,

        LAG(transactions) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_transactions,

        LAG(api_requests) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_api_requests,

        LAG(
            average_daily_active_customers
        ) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_active_customers,

        LAG(cost_per_transaction) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_cost_per_transaction,

        LAG(cost_per_active_customer) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_cost_per_active_customer,

        LAG(cost_per_api_request) OVER (
            PARTITION BY
                provider_name,
                application_name,
                department_name,
                cost_center,
                billing_currency

            ORDER BY unit_economics_month
        ) AS prior_cost_per_api_request

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics`
            AS unit_economics
),

calculated_changes AS (
    SELECT
        *,

        CAST(
            total_allocated_cost
                - prior_total_allocated_cost
            AS NUMERIC
        ) AS cost_change,

        CAST(
            SAFE_DIVIDE(
                total_allocated_cost
                    - prior_total_allocated_cost,

                ABS(prior_total_allocated_cost)
            )
            AS NUMERIC
        ) AS cost_change_pct,

        CAST(
            transactions
                - prior_transactions
            AS NUMERIC
        ) AS transaction_change,

        CAST(
            SAFE_DIVIDE(
                transactions
                    - prior_transactions,

                ABS(prior_transactions)
            )
            AS NUMERIC
        ) AS transaction_change_pct,

        CAST(
            api_requests
                - prior_api_requests
            AS NUMERIC
        ) AS api_request_change,

        CAST(
            SAFE_DIVIDE(
                api_requests
                    - prior_api_requests,

                ABS(prior_api_requests)
            )
            AS NUMERIC
        ) AS api_request_change_pct,

        CAST(
            cost_per_transaction
                - prior_cost_per_transaction
            AS NUMERIC
        ) AS cost_per_transaction_change,

        CAST(
            SAFE_DIVIDE(
                cost_per_transaction
                    - prior_cost_per_transaction,

                ABS(prior_cost_per_transaction)
            )
            AS NUMERIC
        ) AS cost_per_transaction_change_pct,

        CAST(
            SAFE_DIVIDE(
                cost_per_active_customer
                    - prior_cost_per_active_customer,

                ABS(prior_cost_per_active_customer)
            )
            AS NUMERIC
        ) AS cost_per_active_customer_change_pct,

        CAST(
            SAFE_DIVIDE(
                cost_per_api_request
                    - prior_cost_per_api_request,

                ABS(prior_cost_per_api_request)
            )
            AS NUMERIC
        ) AS cost_per_api_request_change_pct

    FROM metrics_with_prior
)

SELECT
    unit_economics_id,
    unit_economics_month,

    provider_name,
    application_name,
    department_name,
    cost_center,
    owner_name,
    billing_currency,

    total_allocated_cost,
    transactions,
    api_requests,
    average_daily_active_customers,
    revenue,

    cost_per_transaction,
    cost_per_active_customer,
    cost_per_api_request,
    infrastructure_cost_pct_of_revenue,

    prior_total_allocated_cost,
    prior_transactions,
    prior_api_requests,
    prior_active_customers,

    prior_cost_per_transaction,
    prior_cost_per_active_customer,
    prior_cost_per_api_request,

    cost_change,
    cost_change_pct,

    transaction_change,
    transaction_change_pct,

    api_request_change,
    api_request_change_pct,

    cost_per_transaction_change,
    cost_per_transaction_change_pct,

    cost_per_active_customer_change_pct,
    cost_per_api_request_change_pct,

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
        WHEN prior_total_allocated_cost IS NULL
        THEN
            'No prior-period baseline is available.'

        WHEN cost_change > 0
         AND transaction_change > 0
         AND cost_per_transaction_change < 0
        THEN
            'Total cloud cost increased because demand grew, while cost '
            || 'per transaction improved. The platform is scaling efficiently.'

        WHEN cost_change > 0
         AND transaction_change > 0
         AND cost_per_transaction_change > 0
        THEN
            'Cloud cost and demand both increased, but cost grew faster than '
            || 'transactions. Unit economics deteriorated.'

        WHEN cost_change > 0
         AND transaction_change <= 0
        THEN
            'Cloud cost increased without transaction growth. Investigate '
            || 'rate changes, idle capacity, anomalies and new scope.'

        WHEN cost_change < 0
         AND cost_per_transaction_change < 0
        THEN
            'Total cloud cost and cost per transaction both improved.'

        WHEN cost_change < 0
         AND transaction_change < 0
         AND cost_per_transaction_change > 0
        THEN
            'Cloud cost decreased, but demand declined faster. Unit economics '
            || 'worsened despite lower total spend.'

        ELSE
            'Cost and demand moved in different directions. Review the detailed '
            || 'cost, activity and unit-cost changes.'
    END AS unit_economics_interpretation,

    data_quality_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM calculated_changes;

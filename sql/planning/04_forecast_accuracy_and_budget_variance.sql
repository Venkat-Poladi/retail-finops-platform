/*
Purpose:
    Calculate forecast MAPE, forecast bias and actual-to-budget variance.

Grain:
    - Forecast accuracy: provider and all-cloud.
    - Budget variance: month, provider and business target.

Source:
    retail_finops_mart.fct_forecast_version
    retail_finops_mart.mart_budget
    retail_finops_mart.mart_monthly_actuals

Key controls:
    - Zero actuals are excluded from MAPE denominators.
    - Forecast bias retains direction.
    - Budget and forecast remain separate concepts.
    - Actual results are reported without tuning.

Owner:
    Finance and FinOps.

Refresh:
    After forecast and budget refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_forecast_accuracy`

AS

/*
Forecast accuracy definition:

1. Evaluate only finalized one-month-ahead forecasts.
2. Aggregate detailed forecast rows before calculating percentage error.
3. Provider MAPE:
       average monthly provider absolute percentage error.
4. ALL_CLOUD MAPE:
       average monthly all-cloud absolute percentage error.
5. Do not calculate ALL_CLOUD MAPE by averaging provider MAPEs.
*/

WITH actualized_provider_observation AS (
    SELECT
        provider_name,
        forecast_version_month,
        target_month,
        forecast_horizon_months,

        CAST(
            SUM(forecast_cost)
            AS NUMERIC
        ) AS forecast_cost,

        CAST(
            SUM(actual_cost)
            AS NUMERIC
        ) AS actual_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_forecast_version`

    WHERE actual_cost IS NOT NULL
      AND forecast_horizon_months = 1

    GROUP BY
        provider_name,
        forecast_version_month,
        target_month,
        forecast_horizon_months
),

provider_accuracy AS (
    SELECT
        provider_name,

        COUNT(*) AS forecast_observation_count,

        COUNTIF(actual_cost != 0)
            AS mape_observation_count,

        CAST(
            AVG(
                CASE
                    WHEN actual_cost != 0
                    THEN SAFE_DIVIDE(
                        ABS(forecast_cost - actual_cost),
                        ABS(actual_cost)
                    )
                END
            )
            AS NUMERIC
        ) AS forecast_mape,

        CAST(
            SAFE_DIVIDE(
                SUM(forecast_cost - actual_cost),
                SUM(actual_cost)
            )
            AS NUMERIC
        ) AS forecast_bias_pct,

        CAST(
            SUM(forecast_cost)
            AS NUMERIC
        ) AS total_forecast_cost,

        CAST(
            SUM(actual_cost)
            AS NUMERIC
        ) AS total_actual_cost,

        CAST(
            SUM(forecast_cost - actual_cost)
            AS NUMERIC
        ) AS total_forecast_error

    FROM actualized_provider_observation

    GROUP BY provider_name
),

all_cloud_observation AS (
    SELECT
        forecast_version_month,
        target_month,
        forecast_horizon_months,

        CAST(
            SUM(forecast_cost)
            AS NUMERIC
        ) AS forecast_cost,

        CAST(
            SUM(actual_cost)
            AS NUMERIC
        ) AS actual_cost

    FROM actualized_provider_observation

    GROUP BY
        forecast_version_month,
        target_month,
        forecast_horizon_months
),

all_cloud_accuracy AS (
    SELECT
        'ALL_CLOUD' AS provider_name,

        COUNT(*) AS forecast_observation_count,

        COUNTIF(actual_cost != 0)
            AS mape_observation_count,

        CAST(
            AVG(
                CASE
                    WHEN actual_cost != 0
                    THEN SAFE_DIVIDE(
                        ABS(forecast_cost - actual_cost),
                        ABS(actual_cost)
                    )
                END
            )
            AS NUMERIC
        ) AS forecast_mape,

        CAST(
            SAFE_DIVIDE(
                SUM(forecast_cost - actual_cost),
                SUM(actual_cost)
            )
            AS NUMERIC
        ) AS forecast_bias_pct,

        CAST(
            SUM(forecast_cost)
            AS NUMERIC
        ) AS total_forecast_cost,

        CAST(
            SUM(actual_cost)
            AS NUMERIC
        ) AS total_actual_cost,

        CAST(
            SUM(forecast_cost - actual_cost)
            AS NUMERIC
        ) AS total_forecast_error

    FROM all_cloud_observation
),

combined_accuracy AS (
    SELECT
        *
    FROM provider_accuracy

    UNION ALL

    SELECT
        *
    FROM all_cloud_accuracy
)

SELECT
    provider_name,
    forecast_observation_count,
    mape_observation_count,
    forecast_mape,
    forecast_bias_pct,
    total_forecast_cost,
    total_actual_cost,
    total_forecast_error,

    CAST(0.10 AS NUMERIC)
        AS target_mape,

    CASE
        WHEN forecast_mape < 0.10
        THEN 'TARGET_MET'
        ELSE 'TARGET_MISSED'
    END AS mape_target_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM combined_accuracy;

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_budget_variance`

PARTITION BY billing_month

CLUSTER BY
    provider_name,
    application_name,
    department_name,
    cost_center

AS

SELECT
    actual.billing_month,

    actual.provider_name,
    actual.application_name,
    actual.department_name,
    actual.environment_name,
    actual.cost_center,
    actual.owner_name,
    actual.billing_currency,

    budget.budget_version,
    budget.budget_methodology,

    actual.actual_cost,

    budget.approved_budget_cost,

    CAST(
        actual.actual_cost
            - budget.approved_budget_cost
        AS NUMERIC
    ) AS budget_variance,

    CAST(
        SAFE_DIVIDE(
            actual.actual_cost
                - budget.approved_budget_cost,

            ABS(budget.approved_budget_cost)
        )
        AS NUMERIC
    ) AS budget_variance_pct,

    CASE
        WHEN budget.approved_budget_cost IS NULL
        THEN 'No Baseline'

        WHEN SAFE_DIVIDE(
            actual.actual_cost
                - budget.approved_budget_cost,

            ABS(budget.approved_budget_cost)
        ) < -0.05
        THEN 'Favorable'

        WHEN ABS(
            SAFE_DIVIDE(
                actual.actual_cost
                    - budget.approved_budget_cost,

                ABS(budget.approved_budget_cost)
            )
        ) <= 0.05
        THEN 'On Plan'

        WHEN SAFE_DIVIDE(
            actual.actual_cost
                - budget.approved_budget_cost,

            ABS(budget.approved_budget_cost)
        ) <= 0.10
        THEN 'Watch'

        WHEN SAFE_DIVIDE(
            actual.actual_cost
                - budget.approved_budget_cost,

            ABS(budget.approved_budget_cost)
        ) <= 0.20
        THEN 'Unfavorable'

        ELSE 'Critical'
    END AS financial_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
        AS actual

LEFT JOIN
    `__PROJECT_ID__.retail_finops_mart.mart_budget`
        AS budget

    ON budget.budget_month
        = actual.billing_month

   AND budget.provider_name
        = actual.provider_name

   AND budget.application_name
        = actual.application_name

   AND budget.department_name
        = actual.department_name

   AND budget.environment_name
        = actual.environment_name

   AND budget.cost_center
        = actual.cost_center

   AND budget.billing_currency
        = actual.billing_currency;

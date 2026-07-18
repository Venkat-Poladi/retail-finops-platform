/*
Purpose:
    Create historical one-month-ahead forecast versions.

Method:
    Forecast =
        70% latest completed month
        +
        30% trailing three-month average.

Grain:
    One row per forecast version, target month, provider and
    allocated business target.

Source:
    retail_finops_mart.mart_monthly_actuals

Key controls:
    - Every forecast uses only information available before
      the target month.
    - Historical forecast versions remain in the table.
    - Final actual is retained for accuracy measurement.
    - No forecast is edited to improve MAPE.

Owner:
    Finance and FinOps.

Refresh:
    After monthly actuals refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_forecast_version`

PARTITION BY target_month

CLUSTER BY
    provider_name,
    application_name,
    forecast_version_month

AS

WITH actuals AS (
    SELECT
        billing_month,
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        billing_currency,
        actual_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
),

month_boundaries AS (
    SELECT
        MIN(billing_month) AS minimum_month

    FROM actuals
),

forecast_targets AS (
    SELECT
        actual.*

    FROM actuals AS actual

    CROSS JOIN month_boundaries

    WHERE actual.billing_month
        >= DATE_ADD(
            minimum_month,
            INTERVAL 3 MONTH
        )
),

forecast_inputs AS (
    SELECT
        target.billing_month
            AS target_month,

        DATE_SUB(
            target.billing_month,
            INTERVAL 1 MONTH
        ) AS forecast_version_month,

        target.provider_name,
        target.application_name,
        target.department_name,
        target.environment_name,
        target.cost_center,
        target.owner_name,
        target.billing_currency,

        target.actual_cost,

        MAX(
            CASE
                WHEN history.billing_month
                    = DATE_SUB(
                        target.billing_month,
                        INTERVAL 1 MONTH
                    )
                THEN history.actual_cost
            END
        ) AS current_run_rate_cost,

        AVG(history.actual_cost)
            AS trailing_three_month_average_cost,

        COUNT(history.billing_month)
            AS historical_month_count

    FROM forecast_targets AS target

    LEFT JOIN actuals AS history

        ON history.provider_name
            = target.provider_name

       AND history.application_name
            = target.application_name

       AND history.department_name
            = target.department_name

       AND history.environment_name
            = target.environment_name

       AND history.cost_center
            = target.cost_center

       AND history.billing_currency
            = target.billing_currency

       AND history.billing_month BETWEEN
            DATE_SUB(
                target.billing_month,
                INTERVAL 3 MONTH
            )
            AND
            DATE_SUB(
                target.billing_month,
                INTERVAL 1 MONTH
            )

    GROUP BY
        target_month,
        forecast_version_month,
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        billing_currency,
        actual_cost
),

calculated_forecast AS (
    SELECT
        *,

        CAST(
            COALESCE(
                (
                    0.70
                    *
                    CAST(
                        current_run_rate_cost
                        AS FLOAT64
                    )
                )
                +
                (
                    0.30
                    *
                    CAST(
                        trailing_three_month_average_cost
                        AS FLOAT64
                    )
                ),

                CAST(
                    current_run_rate_cost
                    AS FLOAT64
                ),

                CAST(
                    trailing_three_month_average_cost
                    AS FLOAT64
                ),

                0
            )
            AS NUMERIC
        ) AS forecast_cost

    FROM forecast_inputs
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                CAST(forecast_version_month AS STRING),
                '|',
                CAST(target_month AS STRING),
                '|',
                provider_name,
                '|',
                application_name,
                '|',
                department_name,
                '|',
                environment_name,
                '|',
                cost_center
            )
        )
    ) AS forecast_version_id,

    forecast_version_month,
    target_month,

    provider_name,
    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,
    billing_currency,

    CAST(current_run_rate_cost AS NUMERIC)
        AS current_run_rate_cost,

    CAST(
        trailing_three_month_average_cost
        AS NUMERIC
    ) AS historical_average_cost,

    historical_month_count,

    CAST(0.70 AS NUMERIC)
        AS run_rate_weight,

    CAST(0.30 AS NUMERIC)
        AS historical_weight,

    forecast_cost,
    actual_cost,

    CAST(
        forecast_cost - actual_cost
        AS NUMERIC
    ) AS forecast_error,

    CAST(
        SAFE_DIVIDE(
            ABS(forecast_cost - actual_cost),
            ABS(actual_cost)
        )
        AS NUMERIC
    ) AS absolute_percentage_error,

    '70_PERCENT_RUN_RATE_30_PERCENT_TRAILING_3_MONTH_AVERAGE'
        AS forecast_methodology,

    1 AS forecast_horizon_months,

    TRUE AS is_modeled,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM calculated_forecast;
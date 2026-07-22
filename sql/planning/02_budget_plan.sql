/*
Purpose:
    Create a modeled approved budget using the initial three months
    of finalized actuals.

Method:
    - The latest available actual in the first three months becomes
      the baseline.
    - Growth is calculated from the earliest to latest available
      initial-period actual.
    - The budget compounds the observed monthly growth rate.
    - The budget is not altered afterward to match actual results.

Grain:
    One row per budget month, provider and business target.

Source:
    retail_finops_mart.mart_monthly_actuals

Key controls:
    - Initial three months only establish assumptions.
    - Later actuals do not change the original budget methodology.
    - Budget version and methodology remain visible.

Owner:
    Finance and FinOps.

Refresh:
    Rebuilt deterministically from approved actuals.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_budget`

PARTITION BY budget_month

CLUSTER BY
    provider_name,
    application_name,
    department_name,
    cost_center

AS

WITH month_sequence AS (
    SELECT
        billing_month,

        ROW_NUMBER() OVER (
            ORDER BY billing_month
        ) AS month_number

    FROM (
        SELECT DISTINCT
            billing_month

        FROM
            `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
    )
),

initial_actuals AS (
    SELECT
        actual.billing_month,
        sequence.month_number,

        actual.provider_name,
        actual.application_name,
        actual.department_name,
        actual.environment_name,
        actual.cost_center,
        actual.owner_name,
        actual.billing_currency,
        actual.actual_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_monthly_actuals`
            AS actual

    INNER JOIN month_sequence AS sequence
        USING (billing_month)

    WHERE sequence.month_number <= 3
),

baseline_by_scope AS (
    SELECT
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        billing_currency,

        ARRAY_AGG(
            STRUCT(
                billing_month,
                actual_cost
            )
            ORDER BY billing_month
            LIMIT 1
        )[OFFSET(0)] AS first_actual,

        ARRAY_AGG(
            STRUCT(
                billing_month,
                actual_cost
            )
            ORDER BY billing_month DESC
            LIMIT 1
        )[OFFSET(0)] AS baseline_actual

    FROM initial_actuals

    GROUP BY
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        billing_currency
),

budget_assumptions AS (
    SELECT
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        billing_currency,

        baseline_actual.billing_month
            AS baseline_month,

        CAST(
            baseline_actual.actual_cost
            AS NUMERIC
        ) AS baseline_cost,

        CASE
            WHEN first_actual.actual_cost > 0
             AND baseline_actual.actual_cost > 0
             AND DATE_DIFF(
                    baseline_actual.billing_month,
                    first_actual.billing_month,
                    MONTH
                 ) > 0

            THEN POW(
                SAFE_DIVIDE(
                    CAST(
                        baseline_actual.actual_cost
                        AS FLOAT64
                    ),
                    CAST(
                        first_actual.actual_cost
                        AS FLOAT64
                    )
                ),
                SAFE_DIVIDE(
                    1.0,
                    DATE_DIFF(
                        baseline_actual.billing_month,
                        first_actual.billing_month,
                        MONTH
                    )
                )
            ) - 1

            ELSE 0
        END AS modeled_monthly_growth_rate

    FROM baseline_by_scope
),

budget_months AS (
    SELECT
        billing_month AS budget_month

    FROM month_sequence

    WHERE month_number >= 4
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                'MODELED_BUDGET_V1|',
                CAST(month.budget_month AS STRING),
                '|',
                assumption.provider_name,
                '|',
                assumption.application_name,
                '|',
                assumption.department_name,
                '|',
                assumption.environment_name,
                '|',
                assumption.cost_center
            )
        )
    ) AS budget_record_id,

    'MODELED_BUDGET_V1'
        AS budget_version,

    month.budget_month,

    assumption.provider_name,
    assumption.application_name,
    assumption.department_name,
    assumption.environment_name,
    assumption.cost_center,
    assumption.owner_name,
    assumption.billing_currency,

    assumption.baseline_month,
    assumption.baseline_cost,

    CAST(
        assumption.modeled_monthly_growth_rate
        AS NUMERIC
    ) AS modeled_monthly_growth_rate,

    CAST(
        CAST(assumption.baseline_cost AS FLOAT64)
        *
        POW(
            1 + assumption.modeled_monthly_growth_rate,

            DATE_DIFF(
                month.budget_month,
                assumption.baseline_month,
                MONTH
            )
        )
        AS NUMERIC
    ) AS approved_budget_cost,

    'INITIAL_THREE_MONTH_BASELINE_WITH_COMPOUNDED_SCOPE_GROWTH'
        AS budget_methodology,

    TRUE AS is_modeled,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM budget_assumptions AS assumption

CROSS JOIN budget_months AS month

WHERE month.budget_month
    > assumption.baseline_month;

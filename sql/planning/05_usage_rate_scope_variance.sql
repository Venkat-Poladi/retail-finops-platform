/*
Purpose:
    Explain monthly cost change using usage, rate and scope effects.

Definitions:
    Usage effect =
        (current quantity - prior quantity) * prior effective rate

    Rate effect =
        current quantity * (current rate - prior rate)

    Scope effect =
        remaining cost change not represented by usage and rate,
        including new, retired, zero-quantity and non-usage charges.

Grain:
    One row per current month, provider, business target,
    service, SKU and charge category.

Source:
    retail_finops_core.vw_cloud_cost_allocated

Key controls:
    Usage effect + rate effect + scope effect
        = total cost change.

Owner:
    Finance and FinOps.

Refresh:
    After allocation refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_variance_drivers`

PARTITION BY billing_month

CLUSTER BY
    provider_name,
    application_name,
    service_name,
    charge_category

AS

WITH monthly_cost_by_key AS (
    SELECT
        DATE_TRUNC(
            DATE(charge_period_start),
            MONTH
        ) AS billing_month,

        provider_name,

        COALESCE(
            NULLIF(TRIM(target_application_name), ''),
            'Unallocated'
        ) AS application_name,

        COALESCE(
            NULLIF(TRIM(target_department_name), ''),
            'Unallocated'
        ) AS department_name,

        COALESCE(
            NULLIF(TRIM(target_environment_name), ''),
            'Unallocated'
        ) AS environment_name,

        COALESCE(
            NULLIF(TRIM(target_cost_center), ''),
            'Unallocated'
        ) AS cost_center,

        COALESCE(
            NULLIF(TRIM(service_name), ''),
            'Unknown Service'
        ) AS service_name,

        COALESCE(
            NULLIF(TRIM(sku_id), ''),
            'UNKNOWN_SKU'
        ) AS sku_id,

        COALESCE(
            NULLIF(TRIM(sku_name), ''),
            'Unknown SKU'
        ) AS sku_name,

        charge_category,
        billing_currency,

        CAST(
            SUM(
                CASE
                    WHEN UPPER(charge_category) = 'USAGE'
                     AND consumed_quantity > 0
                    THEN
                        consumed_quantity
                            * allocation_weight
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS allocated_quantity,

        CAST(
            SUM(allocated_cost)
            AS NUMERIC
        ) AS allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.vw_cloud_cost_allocated`

    GROUP BY
        billing_month,
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        service_name,
        sku_id,
        sku_name,
        charge_category,
        billing_currency
),

month_boundaries AS (
    SELECT
        MIN(billing_month) AS minimum_month,
        MAX(billing_month) AS maximum_month

    FROM monthly_cost_by_key
),

key_month_universe AS (
    SELECT
        billing_month,
        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        service_name,
        sku_id,
        sku_name,
        charge_category,
        billing_currency

    FROM monthly_cost_by_key

    CROSS JOIN month_boundaries

    WHERE billing_month > minimum_month

    UNION DISTINCT

    SELECT
        DATE_ADD(
            billing_month,
            INTERVAL 1 MONTH
        ) AS billing_month,

        provider_name,
        application_name,
        department_name,
        environment_name,
        cost_center,
        service_name,
        sku_id,
        sku_name,
        charge_category,
        billing_currency

    FROM monthly_cost_by_key

    CROSS JOIN month_boundaries

    WHERE DATE_ADD(
        billing_month,
        INTERVAL 1 MONTH
    ) <= maximum_month
),

current_and_prior AS (
    SELECT
        universe.billing_month,

        universe.provider_name,
        universe.application_name,
        universe.department_name,
        universe.environment_name,
        universe.cost_center,
        universe.service_name,
        universe.sku_id,
        universe.sku_name,
        universe.charge_category,
        universe.billing_currency,

        COALESCE(
            current_month.allocated_quantity,
            0
        ) AS current_quantity,

        COALESCE(
            prior_month.allocated_quantity,
            0
        ) AS prior_quantity,

        COALESCE(
            current_month.allocated_cost,
            0
        ) AS current_cost,

        COALESCE(
            prior_month.allocated_cost,
            0
        ) AS prior_cost

    FROM key_month_universe AS universe

    LEFT JOIN monthly_cost_by_key AS current_month

        ON current_month.billing_month
            = universe.billing_month

       AND current_month.provider_name
            = universe.provider_name

       AND current_month.application_name
            = universe.application_name

       AND current_month.department_name
            = universe.department_name

       AND current_month.environment_name
            = universe.environment_name

       AND current_month.cost_center
            = universe.cost_center

       AND current_month.service_name
            = universe.service_name

       AND current_month.sku_id
            = universe.sku_id

       AND current_month.sku_name
            = universe.sku_name

       AND current_month.charge_category
            = universe.charge_category

       AND current_month.billing_currency
            = universe.billing_currency

    LEFT JOIN monthly_cost_by_key AS prior_month

        ON prior_month.billing_month
            = DATE_SUB(
                universe.billing_month,
                INTERVAL 1 MONTH
            )

       AND prior_month.provider_name
            = universe.provider_name

       AND prior_month.application_name
            = universe.application_name

       AND prior_month.department_name
            = universe.department_name

       AND prior_month.environment_name
            = universe.environment_name

       AND prior_month.cost_center
            = universe.cost_center

       AND prior_month.service_name
            = universe.service_name

       AND prior_month.sku_id
            = universe.sku_id

       AND prior_month.sku_name
            = universe.sku_name

       AND prior_month.charge_category
            = universe.charge_category

       AND prior_month.billing_currency
            = universe.billing_currency
),

rate_inputs AS (
    SELECT
        *,

        CAST(
            SAFE_DIVIDE(
                current_cost,
                current_quantity
            )
            AS NUMERIC
        ) AS current_effective_rate,

        CAST(
            SAFE_DIVIDE(
                prior_cost,
                prior_quantity
            )
            AS NUMERIC
        ) AS prior_effective_rate,

        CAST(
            current_cost - prior_cost
            AS NUMERIC
        ) AS total_cost_change

    FROM current_and_prior
),

usage_and_rate AS (
    SELECT
        *,

        CAST(
            CASE
                WHEN current_quantity > 0
                 AND prior_quantity > 0

                THEN
                    (current_quantity - prior_quantity)
                    *
                    prior_effective_rate

                ELSE 0
            END
            AS NUMERIC
        ) AS usage_effect,

        CAST(
            CASE
                WHEN current_quantity > 0
                 AND prior_quantity > 0

                THEN
                    current_quantity
                    *
                    (
                        current_effective_rate
                        - prior_effective_rate
                    )

                ELSE 0
            END
            AS NUMERIC
        ) AS rate_effect

    FROM rate_inputs
),

complete_decomposition AS (
    SELECT
        *,

        CAST(
            total_cost_change
                - usage_effect
                - rate_effect
            AS NUMERIC
        ) AS scope_effect

    FROM usage_and_rate
)

SELECT
    billing_month,

    provider_name,
    application_name,
    department_name,
    environment_name,
    cost_center,
    service_name,
    sku_id,
    sku_name,
    charge_category,
    billing_currency,

    prior_quantity,
    current_quantity,

    prior_effective_rate,
    current_effective_rate,

    prior_cost,
    current_cost,
    total_cost_change,

    usage_effect,
    rate_effect,
    scope_effect,

    CAST(
        usage_effect
            + rate_effect
            + scope_effect
            - total_cost_change
        AS NUMERIC
    ) AS decomposition_variance,

    CASE
        WHEN prior_quantity = 0
         AND current_quantity > 0
        THEN 'NEW_SCOPE'

        WHEN prior_quantity > 0
         AND current_quantity = 0
        THEN 'RETIRED_SCOPE'

        WHEN UPPER(charge_category) != 'USAGE'
        THEN 'NON_USAGE_CHARGE'

        WHEN prior_quantity = 0
          OR current_quantity = 0
        THEN 'ZERO_QUANTITY'

        ELSE 'CONTINUING_USAGE'
    END AS scope_classification,

    CASE
        WHEN ABS(
            usage_effect
                + rate_effect
                + scope_effect
                - total_cost_change
        ) <= 0.01
        THEN 'PASS'

        ELSE 'FAIL'
    END AS decomposition_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM complete_decomposition;

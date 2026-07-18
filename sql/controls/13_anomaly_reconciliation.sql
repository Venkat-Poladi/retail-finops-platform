/*
Purpose:
    Reconcile anomaly-detection inputs and source-detail outputs.

Grain:
    One row per reconciliation check.

Source:
    retail_finops_core.fct_cloud_cost
    retail_finops_mart.mart_daily_cost_series
    retail_finops_mart.fct_cost_anomaly
    retail_finops_mart.fct_anomaly_source_detail

Key controls:
    - Daily total cost reconciles to fact cost.
    - Anomaly source detail reconciles to anomaly actual cost.
    - Same-source SQL tolerance is $0.01.

Owner:
    FinOps Analytics.

Refresh:
    After anomaly source-detail refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.anomaly_reconciliation_control`

AS

WITH fact_by_provider AS (
    SELECT
        provider_name,

        CAST(
            SUM(billed_cost)
            AS NUMERIC
        ) AS fact_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`

    GROUP BY provider_name
),

daily_by_provider AS (
    SELECT
        provider_name,

        CAST(
            SUM(daily_total_cost)
            AS NUMERIC
        ) AS daily_series_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_daily_cost_series`

    GROUP BY provider_name
),

provider_reconciliation AS (
    SELECT
        fact.provider_name,
        fact.fact_cost,
        daily.daily_series_cost,

        CAST(
            daily.daily_series_cost
                - fact.fact_cost
            AS NUMERIC
        ) AS reconciliation_variance

    FROM fact_by_provider AS fact

    LEFT JOIN daily_by_provider AS daily
        USING (provider_name)
),

all_cloud_reconciliation AS (
    SELECT
        'ALL_CLOUD' AS provider_name,

        CAST(
            SUM(fact_cost)
            AS NUMERIC
        ) AS fact_cost,

        CAST(
            SUM(daily_series_cost)
            AS NUMERIC
        ) AS daily_series_cost,

        CAST(
            SUM(daily_series_cost)
                - SUM(fact_cost)
            AS NUMERIC
        ) AS reconciliation_variance

    FROM provider_reconciliation
),

anomaly_detail_by_event AS (
    SELECT
        anomaly.anomaly_id,
        anomaly.actual_cost,

        CAST(
            COALESCE(
                SUM(detail.contribution_cost),
                0
            )
            AS NUMERIC
        ) AS detail_contribution_cost

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_cost_anomaly`
            AS anomaly

    LEFT JOIN
        `__PROJECT_ID__.retail_finops_mart.fct_anomaly_source_detail`
            AS detail

        USING (anomaly_id)

    GROUP BY
        anomaly.anomaly_id,
        anomaly.actual_cost
),

controls AS (
    SELECT
        CONCAT(
            'DAILY_SERIES_TO_FACT_',
            provider_name
        ) AS check_name,

        provider_name,

        fact_cost AS source_control_total,

        daily_series_cost
            AS output_control_total,

        reconciliation_variance,

        NUMERIC '0.01'
            AS tolerance,

        CASE
            WHEN ABS(reconciliation_variance)
                    <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Daily series must reconcile to approved fact cost.'
            AS check_description

    FROM provider_reconciliation

    UNION ALL

    SELECT
        'DAILY_SERIES_TO_FACT_ALL_CLOUD',
        provider_name,
        fact_cost,
        daily_series_cost,
        reconciliation_variance,
        NUMERIC '0.01',

        CASE
            WHEN ABS(reconciliation_variance)
                    <= NUMERIC '0.01'
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'All-cloud daily series must reconcile to fact cost.'

    FROM all_cloud_reconciliation

    UNION ALL

    SELECT
        'ANOMALY_SOURCE_DETAIL_RECONCILIATION',
        'ALL_CLOUD',

        CAST(
            SUM(actual_cost)
            AS NUMERIC
        ),

        CAST(
            SUM(detail_contribution_cost)
            AS NUMERIC
        ),

        CAST(
            SUM(detail_contribution_cost)
                - SUM(actual_cost)
            AS NUMERIC
        ),

        NUMERIC '0.01',

        CASE
            WHEN COUNTIF(
                ABS(
                    detail_contribution_cost
                        - actual_cost
                ) > NUMERIC '0.01'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every anomaly must reconcile to its contributing fact records.'

    FROM anomaly_detail_by_event
)

SELECT
    check_name,
    provider_name,
    source_control_total,
    output_control_total,
    reconciliation_variance,
    tolerance,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM controls;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.anomaly_reconciliation_control`

ORDER BY check_name;
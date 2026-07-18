/*
Purpose:
    Create anomaly summaries for Excel and Power BI.

Grain:
    One row per anomaly month, provider and severity.

Source:
    retail_finops_mart.fct_cost_anomaly

Key controls:
    - Warning and Critical remain separate.
    - Financial impact is calculated from anomaly variance.
    - Owner and action completeness remain measurable.

Owner:
    FinOps Analytics.

Refresh:
    After fct_cost_anomaly refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_anomaly_summary`

PARTITION BY anomaly_month

CLUSTER BY
    provider_name,
    anomaly_severity

AS

SELECT
    DATE_TRUNC(
        anomaly_date,
        MONTH
    ) AS anomaly_month,

    provider_name,
    anomaly_severity,

    COUNT(*)
        AS anomaly_count,

    COUNT(DISTINCT application_name)
        AS affected_application_count,

    COUNT(DISTINCT service_name)
        AS affected_service_count,

    COUNT(DISTINCT owner_name)
        AS affected_owner_count,

    CAST(
        SUM(baseline_cost)
        AS NUMERIC
    ) AS total_baseline_cost,

    CAST(
        SUM(actual_cost)
        AS NUMERIC
    ) AS total_actual_cost,

    CAST(
        SUM(absolute_variance)
        AS NUMERIC
    ) AS total_anomaly_impact,

    CAST(
        AVG(relative_variance)
        AS NUMERIC
    ) AS average_relative_variance,

    MAX(absolute_variance)
        AS maximum_absolute_variance,

    COUNTIF(
        owner_name IS NULL
        OR TRIM(owner_name) = ''
    ) AS missing_owner_count,

    COUNTIF(
        recommended_action IS NULL
        OR TRIM(recommended_action) = ''
    ) AS missing_action_count,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_mart.fct_cost_anomaly`

GROUP BY
    anomaly_month,
    provider_name,
    anomaly_severity;
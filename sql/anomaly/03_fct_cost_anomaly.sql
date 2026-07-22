/*
Purpose:
    Create the material cloud-cost anomaly fact table.

Grain:
    One row per detected anomaly event.

Source:
    retail_finops_mart.mart_cost_anomaly_score

Key controls:
    - Only Warning and Critical events enter the anomaly fact.
    - Every anomaly contains baseline, actual and variance.
    - Every anomaly contains an accountable owner.
    - Every anomaly contains a recommended action.
    - Thresholds and baseline methodology remain visible.

Owner:
    FinOps Analytics.

Refresh:
    After mart_cost_anomaly_score refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_cost_anomaly`

PARTITION BY anomaly_date

CLUSTER BY
    anomaly_severity,
    provider_name,
    application_name,
    service_name

AS

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                anomaly_score_id,
                '|COST_ANOMALY'
            )
        )
    ) AS anomaly_id,

    anomaly_score_id,
    cost_series_id,
    anomaly_date,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    application_name,
    department_name,
    environment_name,
    cost_center,

    COALESCE(
        NULLIF(TRIM(owner_name), ''),
        'FinOps Lead'
    ) AS owner_name,

    service_category,
    service_name,
    resource_id,
    resource_name,
    region_name,

    billing_currency,

    baseline_cost,
    actual_cost,
    absolute_variance,
    relative_variance,

    anomaly_severity,
    anomaly_direction,

    baseline_observation_count,
    trailing_14d_median_cost,
    same_weekday_history_count,
    same_weekday_median_cost,
    baseline_method,

    warning_relative_threshold,
    warning_absolute_threshold,
    critical_relative_threshold,
    critical_absolute_threshold,

    source_row_count,
    source_record_count,

    CASE
        WHEN service_category = 'Network'
        THEN
            'Review egress, NAT, cross-region and cross-zone traffic. '
            || 'Confirm whether a routing or deployment change caused the increase.'

        WHEN service_category = 'Observability'
        THEN
            'Review log-ingestion volume, debug logging, retention settings '
            || 'and newly enabled monitoring sources.'

        WHEN service_category = 'Compute'
        THEN
            'Review instance scaling, runtime hours, recent deployments '
            || 'and unexpected capacity increases.'

        WHEN service_category = 'Serverless'
        THEN
            'Review request volume, invocation loops, concurrency settings '
            || 'and recent deployment changes.'

        WHEN service_category = 'Database'
        THEN
            'Review transaction volume, provisioned capacity, backups, '
            || 'storage growth and inefficient queries.'

        WHEN service_category = 'Storage'
        THEN
            'Review storage growth, request volume, snapshots, replication '
            || 'and lifecycle-policy coverage.'

        WHEN service_category = 'AI'
        THEN
            'Review the related training or inference workload, request growth '
            || 'and whether the high-cost activity was planned.'

        WHEN service_category = 'Marketplace'
        THEN
            'Review new subscriptions, license-count changes and '
            || 'marketplace contract activity.'

        ELSE
            'Review source records, recent deployments, workload changes '
            || 'and business events associated with this cost increase.'
    END AS recommended_action,

    CASE
        WHEN environment_name = 'prod'
        THEN 'High'
        ELSE 'Medium'
    END AS investigation_priority,

    'Open'
        AS review_status,

    DATE_ADD(
        anomaly_date,
        INTERVAL
            CASE
                WHEN anomaly_severity = 'Critical'
                THEN 1
                ELSE 3
            END
        DAY
    ) AS target_review_date,

    TRUE AS is_material,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_mart.mart_cost_anomaly_score`

WHERE anomaly_severity IN (
    'Warning',
    'Critical'
);

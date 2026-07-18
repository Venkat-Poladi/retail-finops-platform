/*
Purpose:
    Create the daily cost series used by anomaly detection.

Grain:
    One row per date, provider, billing hierarchy, business attribution,
    service and resource.

Source:
    retail_finops_core.fct_cloud_cost

Key controls:
    - Uses only the approved cloud-cost fact table.
    - daily_total_cost includes every approved financial charge.
    - daily_positive_usage_cost includes positive Usage cost only.
    - Credits, refunds and adjustments remain in daily_total_cost.
    - Source-row counts remain available.
    - Business and resource ownership remain visible.

Owner:
    FinOps Analytics.

Refresh:
    After fct_cloud_cost refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_daily_cost_series`

PARTITION BY anomaly_date

CLUSTER BY
    provider_name,
    application_name,
    service_name,
    resource_id

AS

WITH normalized_fact AS (
    SELECT
        DATE(charge_period_start)
            AS anomaly_date,

        provider_name,

        COALESCE(
            NULLIF(TRIM(billing_account_id), ''),
            'UNKNOWN_BILLING_ACCOUNT'
        ) AS billing_account_id,

        COALESCE(
            NULLIF(TRIM(sub_account_id), ''),
            'UNKNOWN_SUB_ACCOUNT'
        ) AS sub_account_id,

        COALESCE(
            NULLIF(TRIM(project_id), ''),
            'NOT_APPLICABLE'
        ) AS project_id,

        COALESCE(
            NULLIF(TRIM(application_name), ''),
            'Unallocated'
        ) AS application_name,

        COALESCE(
            NULLIF(TRIM(department_name), ''),
            'Unallocated'
        ) AS department_name,

        COALESCE(
            NULLIF(TRIM(environment_name), ''),
            'Unallocated'
        ) AS environment_name,

        COALESCE(
            NULLIF(TRIM(cost_center), ''),
            'Unallocated'
        ) AS cost_center,

        COALESCE(
            NULLIF(TRIM(owner_name), ''),
            'FinOps Lead'
        ) AS owner_name,

        COALESCE(
            NULLIF(TRIM(service_category), ''),
            'Other'
        ) AS service_category,

        COALESCE(
            NULLIF(TRIM(service_name), ''),
            'Unknown Service'
        ) AS service_name,

        COALESCE(
            NULLIF(TRIM(resource_id), ''),
            'UNKNOWN_RESOURCE'
        ) AS resource_id,

        COALESCE(
            NULLIF(TRIM(resource_name), ''),
            'Unknown Resource'
        ) AS resource_name,

        COALESCE(
            NULLIF(TRIM(region_name), ''),
            'global'
        ) AS region_name,

        billing_currency,
        record_id,
        charge_category,
        billed_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
),

daily_cost AS (
    SELECT
        anomaly_date,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        service_category,
        service_name,
        resource_id,
        resource_name,
        region_name,

        billing_currency,

        COUNT(*) AS source_row_count,

        COUNT(DISTINCT record_id)
            AS source_record_count,

        CAST(
            SUM(billed_cost)
            AS NUMERIC
        ) AS daily_total_cost,

        CAST(
            SUM(
                CASE
                    WHEN UPPER(charge_category) = 'USAGE'
                     AND billed_cost > 0
                    THEN billed_cost
                    ELSE 0
                END
            )
            AS NUMERIC
        ) AS daily_positive_usage_cost

    FROM normalized_fact

    GROUP BY
        anomaly_date,
        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,
        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        service_category,
        service_name,
        resource_id,
        resource_name,
        region_name,
        billing_currency
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                provider_name,
                '|',
                billing_account_id,
                '|',
                sub_account_id,
                '|',
                project_id,
                '|',
                application_name,
                '|',
                department_name,
                '|',
                environment_name,
                '|',
                cost_center,
                '|',
                owner_name,
                '|',
                service_name,
                '|',
                resource_id,
                '|',
                region_name,
                '|',
                billing_currency
            )
        )
    ) AS cost_series_id,

    anomaly_date,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,

    service_category,
    service_name,
    resource_id,
    resource_name,
    region_name,

    billing_currency,

    source_row_count,
    source_record_count,

    daily_total_cost,
    daily_positive_usage_cost,

    EXTRACT(DAYOFWEEK FROM anomaly_date)
        AS day_of_week_number,

    FORMAT_DATE('%A', anomaly_date)
        AS day_of_week_name,

    EXTRACT(DAYOFWEEK FROM anomaly_date)
        IN (1, 7)
        AS is_weekend,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM daily_cost;
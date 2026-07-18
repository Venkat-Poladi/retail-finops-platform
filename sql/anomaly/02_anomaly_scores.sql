/*
Purpose:
    Calculate daily cost-anomaly scores.

Grain:
    One row per daily cost-series row.

Source:
    retail_finops_mart.mart_daily_cost_series

Key controls:
    - Current day is excluded from the baseline.
    - Primary baseline is the prior 14-day median.
    - At least seven prior observations are required.
    - Same-weekday history is used as a seasonal guardrail.
    - Warning requires both relative and absolute thresholds.
    - Critical requires both critical thresholds.

Owner:
    FinOps Analytics.

Refresh:
    After mart_daily_cost_series refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.mart_cost_anomaly_score`

PARTITION BY anomaly_date

CLUSTER BY
    provider_name,
    anomaly_severity,
    application_name,
    service_name

AS

WITH daily_series AS (
    SELECT
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

        day_of_week_number,
        day_of_week_name,
        is_weekend

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_daily_cost_series`
),

trailing_baseline AS (
    SELECT
        current_day.cost_series_id,
        current_day.anomaly_date,

        COUNT(history.anomaly_date)
            AS trailing_history_count,

        APPROX_QUANTILES(
            CAST(
                history.daily_positive_usage_cost
                AS FLOAT64
            ),
            100
        )[SAFE_OFFSET(50)]
            AS trailing_14d_median_cost

    FROM daily_series AS current_day

    LEFT JOIN daily_series AS history

        ON history.cost_series_id
            = current_day.cost_series_id

       AND history.anomaly_date BETWEEN
            DATE_SUB(
                current_day.anomaly_date,
                INTERVAL 14 DAY
            )
            AND
            DATE_SUB(
                current_day.anomaly_date,
                INTERVAL 1 DAY
            )

    GROUP BY
        current_day.cost_series_id,
        current_day.anomaly_date
),

same_weekday_baseline AS (
    SELECT
        current_day.cost_series_id,
        current_day.anomaly_date,

        COUNT(history.anomaly_date)
            AS same_weekday_history_count,

        APPROX_QUANTILES(
            CAST(
                history.daily_positive_usage_cost
                AS FLOAT64
            ),
            100
        )[SAFE_OFFSET(50)]
            AS same_weekday_median_cost

    FROM daily_series AS current_day

    LEFT JOIN daily_series AS history

        ON history.cost_series_id
            = current_day.cost_series_id

       AND history.day_of_week_number
            = current_day.day_of_week_number

       AND history.anomaly_date BETWEEN
            DATE_SUB(
                current_day.anomaly_date,
                INTERVAL 56 DAY
            )
            AND
            DATE_SUB(
                current_day.anomaly_date,
                INTERVAL 1 DAY
            )

    GROUP BY
        current_day.cost_series_id,
        current_day.anomaly_date
),

combined_baseline AS (
    SELECT
        daily.*,

        trailing.trailing_history_count,

        CAST(
            trailing.trailing_14d_median_cost
            AS NUMERIC
        ) AS trailing_14d_median_cost,

        seasonal.same_weekday_history_count,

        CAST(
            seasonal.same_weekday_median_cost
            AS NUMERIC
        ) AS same_weekday_median_cost,

        CAST(
            CASE
                WHEN seasonal.same_weekday_history_count >= 4
                 AND seasonal.same_weekday_median_cost IS NOT NULL
                 AND trailing.trailing_14d_median_cost IS NOT NULL

                THEN GREATEST(
                    seasonal.same_weekday_median_cost,
                    trailing.trailing_14d_median_cost
                )

                ELSE trailing.trailing_14d_median_cost
            END
            AS NUMERIC
        ) AS baseline_cost,

        CASE
            WHEN seasonal.same_weekday_history_count >= 4
             AND seasonal.same_weekday_median_cost IS NOT NULL
            THEN
                '14_DAY_MEDIAN_WITH_SAME_WEEKDAY_GUARDRAIL'

            ELSE
                'TRAILING_14_DAY_MEDIAN'
        END AS baseline_method

    FROM daily_series AS daily

    INNER JOIN trailing_baseline AS trailing
        USING (
            cost_series_id,
            anomaly_date
        )

    INNER JOIN same_weekday_baseline AS seasonal
        USING (
            cost_series_id,
            anomaly_date
        )
),

variance_calculation AS (
    SELECT
        *,

        CAST(
            daily_positive_usage_cost
                - baseline_cost
            AS NUMERIC
        ) AS absolute_variance,

        CAST(
            SAFE_DIVIDE(
                daily_positive_usage_cost
                    - baseline_cost,

                baseline_cost
            )
            AS NUMERIC
        ) AS relative_variance

    FROM combined_baseline
),

classified_scores AS (
    SELECT
        *,

        CASE
            WHEN trailing_history_count < 7
            THEN 'Insufficient History'

            WHEN baseline_cost IS NULL
              OR baseline_cost <= 0
            THEN 'No Baseline'

            WHEN relative_variance >= 1.00
             AND absolute_variance >= 500
            THEN 'Critical'

            WHEN relative_variance >= 0.30
             AND absolute_variance >= 100
            THEN 'Warning'

            ELSE 'Normal'
        END AS anomaly_severity

    FROM variance_calculation
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                cost_series_id,
                '|',
                CAST(anomaly_date AS STRING)
            )
        )
    ) AS anomaly_score_id,

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

    daily_positive_usage_cost
        AS actual_cost,

    trailing_history_count
        AS baseline_observation_count,

    trailing_14d_median_cost,
    same_weekday_history_count,
    same_weekday_median_cost,

    baseline_cost,
    baseline_method,

    absolute_variance,
    relative_variance,

    anomaly_severity,

    anomaly_severity IN (
        'Warning',
        'Critical'
    ) AS is_anomaly,

    'Increase'
        AS anomaly_direction,

    NUMERIC '0.30'
        AS warning_relative_threshold,

    NUMERIC '100'
        AS warning_absolute_threshold,

    NUMERIC '1.00'
        AS critical_relative_threshold,

    NUMERIC '500'
        AS critical_absolute_threshold,

    day_of_week_number,
    day_of_week_name,
    is_weekend,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM classified_scores;
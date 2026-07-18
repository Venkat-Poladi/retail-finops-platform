/*
Purpose:
    Confirm that deliberately injected source-cost anomalies are detected.

Grain:
    One row per expected injected anomaly event.

Source:
    retail_finops_raw.raw_aws_billing
    retail_finops_raw.raw_gcp_billing
    retail_finops_mart.fct_cost_anomaly

Key controls:
    - Expected events come from source injected_scenario fields.
    - AWS and GCP expected events remain provider-specific.
    - All expected spike events must be detected.
    - Detection severity remains visible.

Owner:
    FinOps Analytics.

Refresh:
    After fct_cost_anomaly refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.known_anomaly_detection_control`

AS

WITH expected_aws_anomalies AS (
    SELECT
        'AWS' AS provider_name,

        DATE(line_item_usage_start_date)
            AS anomaly_date,

        COALESCE(
            NULLIF(
                TRIM(
                    resource_tags_user_application
                ),
                ''
            ),
            'Unallocated'
        ) AS application_name,

        product_product_name
            AS service_name,

        injected_scenario,

        COUNT(*) AS expected_source_row_count

    FROM
        `__PROJECT_ID__.retail_finops_raw.raw_aws_billing`

    WHERE REGEXP_CONTAINS(
        LOWER(injected_scenario),
        r'_spike$'
    )

    GROUP BY
        anomaly_date,
        application_name,
        service_name,
        injected_scenario
),

expected_gcp_anomalies AS (
    SELECT
        'GCP' AS provider_name,

        DATE(usage_start_time)
            AS anomaly_date,

        COALESCE(
            NULLIF(
                TRIM(
                    (
                        SELECT label.value

                        FROM UNNEST(labels) AS label

                        WHERE LOWER(label.key)
                            = 'application'

                        LIMIT 1
                    )
                ),
                ''
            ),
            'Unallocated'
        ) AS application_name,

        CAST(service.description AS STRING)
            AS service_name,

        injected_scenario,

        COUNT(*) AS expected_source_row_count

    FROM
        `__PROJECT_ID__.retail_finops_raw.raw_gcp_billing`

    WHERE REGEXP_CONTAINS(
        LOWER(injected_scenario),
        r'_spike$'
    )

    GROUP BY
        anomaly_date,
        application_name,
        service_name,
        injected_scenario
),

expected_anomalies AS (
    SELECT
        provider_name,
        anomaly_date,
        application_name,
        service_name,
        injected_scenario,
        expected_source_row_count

    FROM expected_aws_anomalies

    UNION ALL

    SELECT
        provider_name,
        anomaly_date,
        application_name,
        service_name,
        injected_scenario,
        expected_source_row_count

    FROM expected_gcp_anomalies
),

detected_events AS (
    SELECT
        provider_name,
        anomaly_date,
        application_name,
        service_name,

        COUNT(*) AS detected_anomaly_count,

        STRING_AGG(
            DISTINCT anomaly_severity,
            ', '
            ORDER BY anomaly_severity
        ) AS detected_severity,

        SUM(absolute_variance)
            AS detected_anomaly_impact

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_cost_anomaly`

    GROUP BY
        provider_name,
        anomaly_date,
        application_name,
        service_name
)

SELECT
    TO_HEX(
        SHA256(
            CONCAT(
                expected.provider_name,
                '|',
                CAST(expected.anomaly_date AS STRING),
                '|',
                expected.application_name,
                '|',
                expected.service_name,
                '|',
                expected.injected_scenario
            )
        )
    ) AS expected_anomaly_id,

    expected.provider_name,
    expected.anomaly_date,
    expected.application_name,
    expected.service_name,
    expected.injected_scenario,
    expected.expected_source_row_count,

    COALESCE(
        detected.detected_anomaly_count,
        0
    ) AS detected_anomaly_count,

    detected.detected_severity,
    detected.detected_anomaly_impact,

    detected.detected_anomaly_count > 0
        AS was_detected,

    CASE
        WHEN detected.detected_anomaly_count > 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS detection_status,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM expected_anomalies AS expected

LEFT JOIN detected_events AS detected

    ON detected.provider_name
        = expected.provider_name

   AND detected.anomaly_date
        = expected.anomaly_date

   AND detected.application_name
        = expected.application_name

   AND detected.service_name
        = expected.service_name;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.known_anomaly_detection_control`

ORDER BY
    provider_name,
    anomaly_date;


SELECT
    COUNT(*) AS expected_anomaly_count,

    COUNTIF(was_detected)
        AS detected_anomaly_count,

    COUNTIF(NOT was_detected)
        AS missed_anomaly_count,

    CASE
        WHEN COUNT(*) > 0
         AND COUNTIF(NOT was_detected) = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS known_anomaly_detection_status

FROM
    `__PROJECT_ID__.retail_finops_control.known_anomaly_detection_control`;
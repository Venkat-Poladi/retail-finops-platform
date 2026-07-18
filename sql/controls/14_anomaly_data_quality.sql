/*
Purpose:
    Validate anomaly-table completeness, uniqueness, thresholds,
    ownership, actions and source lineage.

Grain:
    One row per anomaly data-quality check.

Source:
    Anomaly score, fact and source-detail tables.

Key controls:
    - IDs are complete and unique.
    - Thresholds are applied correctly.
    - Every anomaly has owner and action.
    - Every anomaly has source records.
    - Seasonal non-production weekends are not classified Critical.
    - Review statuses use controlled vocabulary.

Owner:
    FinOps Analytics.

Refresh:
    After anomaly reconciliation.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.anomaly_data_quality_control`

AS

WITH anomaly_rows AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_cost_anomaly`
),

anomaly_details AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_mart.fct_anomaly_source_detail`
),

quality_checks AS (
    SELECT
        'NULL_ANOMALY_ID'
            AS check_name,

        'ERROR' AS severity,

        COUNTIF(
            anomaly_id IS NULL
            OR TRIM(anomaly_id) = ''
        ) AS issue_count,

        CASE
            WHEN COUNTIF(
                anomaly_id IS NULL
                OR TRIM(anomaly_id) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'Every anomaly must have anomaly_id.'
            AS check_description

    FROM anomaly_rows

    UNION ALL

    SELECT
        'DUPLICATE_ANOMALY_ID',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'anomaly_id must be unique.'

    FROM (
        SELECT
            anomaly_id

        FROM anomaly_rows

        GROUP BY anomaly_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'NULL_BASELINE_OR_ACTUAL',
        'ERROR',

        COUNTIF(
            baseline_cost IS NULL
            OR actual_cost IS NULL
        ),

        CASE
            WHEN COUNTIF(
                baseline_cost IS NULL
                OR actual_cost IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every anomaly requires baseline and actual cost.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'INSUFFICIENT_BASELINE_HISTORY',
        'ERROR',

        COUNTIF(
            baseline_observation_count < 7
        ),

        CASE
            WHEN COUNTIF(
                baseline_observation_count < 7
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Anomalies require at least seven baseline observations.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'WARNING_THRESHOLD_FAILURE',
        'ERROR',

        COUNTIF(
            anomaly_severity = 'Warning'
            AND (
                relative_variance < 0.30
                OR absolute_variance < 100
            )
        ),

        CASE
            WHEN COUNTIF(
                anomaly_severity = 'Warning'
                AND (
                    relative_variance < 0.30
                    OR absolute_variance < 100
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Warning anomalies must clear both warning thresholds.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'CRITICAL_THRESHOLD_FAILURE',
        'ERROR',

        COUNTIF(
            anomaly_severity = 'Critical'
            AND (
                relative_variance < 1.00
                OR absolute_variance < 500
            )
        ),

        CASE
            WHEN COUNTIF(
                anomaly_severity = 'Critical'
                AND (
                    relative_variance < 1.00
                    OR absolute_variance < 500
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Critical anomalies must clear both critical thresholds.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'UNSUPPORTED_ANOMALY_SEVERITY',
        'ERROR',

        COUNTIF(
            anomaly_severity NOT IN (
                'Warning',
                'Critical'
            )
        ),

        CASE
            WHEN COUNTIF(
                anomaly_severity NOT IN (
                    'Warning',
                    'Critical'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Only Warning and Critical belong in fct_cost_anomaly.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'MISSING_ANOMALY_OWNER',
        'ERROR',

        COUNTIF(
            owner_name IS NULL
            OR TRIM(owner_name) = ''
        ),

        CASE
            WHEN COUNTIF(
                owner_name IS NULL
                OR TRIM(owner_name) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every anomaly requires an accountable owner.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'MISSING_RECOMMENDED_ACTION',
        'ERROR',

        COUNTIF(
            recommended_action IS NULL
            OR TRIM(recommended_action) = ''
        ),

        CASE
            WHEN COUNTIF(
                recommended_action IS NULL
                OR TRIM(recommended_action) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every material anomaly requires a recommended action.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'ANOMALY_WITHOUT_SOURCE_DETAIL',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every anomaly must trace to at least one fact record.'

    FROM anomaly_rows AS anomaly

    LEFT JOIN (
        SELECT DISTINCT
            anomaly_id

        FROM anomaly_details
    ) AS detail

        USING (anomaly_id)

    WHERE detail.anomaly_id IS NULL

    UNION ALL

    SELECT
        'DUPLICATE_ANOMALY_SOURCE_RECORD',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'A fact record must appear only once per anomaly.'

    FROM (
        SELECT
            anomaly_id,
            record_id

        FROM anomaly_details

        GROUP BY
            anomaly_id,
            record_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'MISSING_SOURCE_LINEAGE',
        'ERROR',

        COUNTIF(
            record_id IS NULL
            OR TRIM(record_id) = ''
            OR source_record_id IS NULL
            OR TRIM(source_record_id) = ''
            OR pipeline_run_id IS NULL
            OR TRIM(pipeline_run_id) = ''
            OR source_system IS NULL
            OR TRIM(source_system) = ''
            OR source_file IS NULL
            OR TRIM(source_file) = ''
            OR ingestion_timestamp IS NULL
        ),

        CASE
            WHEN COUNTIF(
                record_id IS NULL
                OR TRIM(record_id) = ''
                OR source_record_id IS NULL
                OR TRIM(source_record_id) = ''
                OR pipeline_run_id IS NULL
                OR TRIM(pipeline_run_id) = ''
                OR source_system IS NULL
                OR TRIM(source_system) = ''
                OR source_file IS NULL
                OR TRIM(source_file) = ''
                OR ingestion_timestamp IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Anomaly detail must retain complete source lineage.'

    FROM anomaly_details

    UNION ALL

    SELECT
        'UNSUPPORTED_REVIEW_STATUS',
        'ERROR',

        COUNTIF(
            review_status NOT IN (
                'Open',
                'Investigating',
                'Resolved',
                'Accepted'
            )
        ),

        CASE
            WHEN COUNTIF(
                review_status NOT IN (
                    'Open',
                    'Investigating',
                    'Resolved',
                    'Accepted'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Anomaly review status must use controlled vocabulary.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'NONPROD_WEEKEND_CRITICAL_ANOMALY',
        'ERROR',

        COUNTIF(
            environment_name = 'nonprod'
            AND EXTRACT(
                DAYOFWEEK
                FROM anomaly_date
            ) IN (1, 7)
            AND anomaly_severity = 'Critical'
        ),

        CASE
            WHEN COUNTIF(
                environment_name = 'nonprod'
                AND EXTRACT(
                    DAYOFWEEK
                    FROM anomaly_date
                ) IN (1, 7)
                AND anomaly_severity = 'Critical'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Expected weekend seasonality must not become Critical.'

    FROM anomaly_rows

    UNION ALL

    SELECT
        'ANOMALY_COUNT_AVAILABLE',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) > 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'The deterministic synthetic data should produce anomalies.'

    FROM anomaly_rows
)

SELECT
    check_name,
    severity,
    issue_count,
    check_status,
    check_description,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM quality_checks;


SELECT
    *

FROM
    `__PROJECT_ID__.retail_finops_control.anomaly_data_quality_control`

ORDER BY
    CASE severity
        WHEN 'ERROR' THEN 1
        ELSE 2
    END,
    check_name;


SELECT
    CASE
        WHEN COUNTIF(
            severity = 'ERROR'
            AND check_status = 'FAIL'
        ) > 0
        THEN 'FAIL'

        ELSE 'PASS'
    END AS overall_anomaly_data_quality_status,

    COUNTIF(
        severity = 'ERROR'
        AND check_status = 'FAIL'
    ) AS failed_error_checks

FROM
    `__PROJECT_ID__.retail_finops_control.anomaly_data_quality_control`;
/*
Purpose:
    Validate unit-economics IDs, grain, mappings, formulas and disclosures.

Grain:
    One row per unit-economics data-quality check.

Source:
    Raw activity
    Dimension reference
    Monthly activity
    Unit-economics marts

Key controls:
    - Activity keys are unique.
    - Workloads map to one business dimension.
    - Unit-economics IDs and grain are unique.
    - Denominators are valid.
    - Unit-cost formulas recalculate.
    - Unallocated cost does not receive fabricated business activity.
    - Synthetic activity is clearly disclosed.

Owner:
    FinOps Analytics.

Refresh:
    After unit-economics reconciliation.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.unit_economics_data_quality_control`

AS

WITH unit_economics AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_mart.mart_unit_economics`
),

quality_checks AS (
    SELECT
        'DUPLICATE_RAW_ACTIVITY_KEY'
            AS check_name,

        'ERROR' AS severity,

        COUNT(*) AS issue_count,

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END AS check_status,

        'activity_date and workload_id must be unique.'
            AS check_description

    FROM (
        SELECT
            activity_date,
            workload_id

        FROM
            `__PROJECT_ID__.retail_finops_raw.raw_business_activity`

        GROUP BY
            activity_date,
            workload_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'DUPLICATE_BUSINESS_DIMENSION_WORKLOAD',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every workload_id must map to one business dimension.'

    FROM (
        SELECT
            workload_id

        FROM
            `__PROJECT_ID__.retail_finops_control.business_dimension_reference`

        GROUP BY workload_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'RAW_ACTIVITY_WITHOUT_DIMENSION',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every activity workload must map to business dimensions.'

    FROM (
        SELECT DISTINCT
            activity.workload_id

        FROM
            `__PROJECT_ID__.retail_finops_raw.raw_business_activity`
                AS activity

        LEFT JOIN
            `__PROJECT_ID__.retail_finops_control.business_dimension_reference`
                AS dimension

            USING (workload_id)

        WHERE dimension.workload_id IS NULL
    )

    UNION ALL

    SELECT
        'NULL_UNIT_ECONOMICS_ID',
        'ERROR',

        COUNTIF(
            unit_economics_id IS NULL
            OR TRIM(unit_economics_id) = ''
        ),

        CASE
            WHEN COUNTIF(
                unit_economics_id IS NULL
                OR TRIM(unit_economics_id) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every unit-economics row requires an ID.'

    FROM unit_economics

    UNION ALL

    SELECT
        'DUPLICATE_UNIT_ECONOMICS_ID',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'unit_economics_id must be unique.'

    FROM (
        SELECT
            unit_economics_id

        FROM unit_economics

        GROUP BY unit_economics_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'DUPLICATE_UNIT_ECONOMICS_GRAIN',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Month, provider, application and cost center must be unique.'

    FROM (
        SELECT
            unit_economics_month,
            provider_name,
            application_name,
            department_name,
            cost_center,
            billing_currency

        FROM unit_economics

        GROUP BY
            unit_economics_month,
            provider_name,
            application_name,
            department_name,
            cost_center,
            billing_currency

        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT
        'INVALID_ACTIVITY_DENOMINATOR',
        'ERROR',

        COUNTIF(
            has_business_activity
            AND (
                transactions <= 0
                OR api_requests <= 0
                OR average_daily_active_customers <= 0
                OR revenue <= 0
            )
        ),

        CASE
            WHEN COUNTIF(
                has_business_activity
                AND (
                    transactions <= 0
                    OR api_requests <= 0
                    OR average_daily_active_customers <= 0
                    OR revenue <= 0
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Matched business applications require positive denominators.'

    FROM unit_economics

    UNION ALL

    SELECT
        'COST_PER_TRANSACTION_MISMATCH',
        'ERROR',

        COUNTIF(
            has_business_activity
            AND ABS(
                cost_per_transaction
                    - SAFE_DIVIDE(
                        total_allocated_cost,
                        transactions
                    )
            ) > NUMERIC '0.000001'
        ),

        CASE
            WHEN COUNTIF(
                has_business_activity
                AND ABS(
                    cost_per_transaction
                        - SAFE_DIVIDE(
                            total_allocated_cost,
                            transactions
                        )
                ) > NUMERIC '0.000001'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Cost per transaction must recalculate from cost and transactions.'

    FROM unit_economics

    UNION ALL

    SELECT
        'COST_PER_ACTIVE_CUSTOMER_MISMATCH',
        'ERROR',

        COUNTIF(
            has_business_activity
            AND ABS(
                cost_per_active_customer
                    - SAFE_DIVIDE(
                        total_allocated_cost,
                        average_daily_active_customers
                    )
            ) > NUMERIC '0.000001'
        ),

        CASE
            WHEN COUNTIF(
                has_business_activity
                AND ABS(
                    cost_per_active_customer
                        - SAFE_DIVIDE(
                            total_allocated_cost,
                            average_daily_active_customers
                        )
                ) > NUMERIC '0.000001'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Cost per active customer must use average daily active customers.'

    FROM unit_economics

    UNION ALL

    SELECT
        'COST_PER_API_REQUEST_MISMATCH',
        'ERROR',

        COUNTIF(
            has_business_activity
            AND ABS(
                cost_per_api_request
                    - SAFE_DIVIDE(
                        total_allocated_cost,
                        api_requests
                    )
            ) > NUMERIC '0.000001'
        ),

        CASE
            WHEN COUNTIF(
                has_business_activity
                AND ABS(
                    cost_per_api_request
                        - SAFE_DIVIDE(
                            total_allocated_cost,
                            api_requests
                        )
                ) > NUMERIC '0.000001'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Cost per API request must recalculate.'

    FROM unit_economics

    UNION ALL

    SELECT
        'INFRASTRUCTURE_REVENUE_PCT_MISMATCH',
        'ERROR',

        COUNTIF(
            has_business_activity
            AND ABS(
                infrastructure_cost_pct_of_revenue
                    - SAFE_DIVIDE(
                        total_allocated_cost,
                        revenue
                    )
            ) > NUMERIC '0.000001'
        ),

        CASE
            WHEN COUNTIF(
                has_business_activity
                AND ABS(
                    infrastructure_cost_pct_of_revenue
                        - SAFE_DIVIDE(
                            total_allocated_cost,
                            revenue
                        )
                ) > NUMERIC '0.000001'
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Infrastructure-cost percentage must recalculate from cost and revenue.'

    FROM unit_economics

    UNION ALL

    SELECT
        'UNALLOCATED_COST_WITH_BUSINESS_UNITS',
        'ERROR',

        COUNTIF(
            application_name = 'Unallocated'
            AND (
                transactions IS NOT NULL
                OR api_requests IS NOT NULL
                OR average_daily_active_customers IS NOT NULL
                OR revenue IS NOT NULL
            )
        ),

        CASE
            WHEN COUNTIF(
                application_name = 'Unallocated'
                AND (
                    transactions IS NOT NULL
                    OR api_requests IS NOT NULL
                    OR average_daily_active_customers IS NOT NULL
                    OR revenue IS NOT NULL
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Unallocated cost must not receive fabricated activity.'

    FROM unit_economics

    UNION ALL

    SELECT
        'BUSINESS_APPLICATION_WITHOUT_ACTIVITY',
        'ERROR',

        COUNTIF(
            application_name NOT IN (
                'Unallocated',
                'Shared Platform'
            )
            AND NOT has_business_activity
        ),

        CASE
            WHEN COUNTIF(
                application_name NOT IN (
                    'Unallocated',
                    'Shared Platform'
                )
                AND NOT has_business_activity
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Business-facing applications must have activity data.'

    FROM unit_economics

    UNION ALL

    SELECT
        'INVALID_DATA_QUALITY_STATUS',
        'ERROR',

        COUNTIF(
            data_quality_status NOT IN (
                'Pass',
                'Pass with Exceptions',
                'Fail',
                'Pending'
            )
        ),

        CASE
            WHEN COUNTIF(
                data_quality_status NOT IN (
                    'Pass',
                    'Pass with Exceptions',
                    'Fail',
                    'Pending'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Data-quality status must use controlled vocabulary.'

    FROM unit_economics

    UNION ALL

    SELECT
        'SYNTHETIC_ACTIVITY_NOT_DISCLOSED',
        'ERROR',

        COUNTIF(
            has_business_activity
            AND NOT is_synthetic_activity
        ),

        CASE
            WHEN COUNTIF(
                has_business_activity
                AND NOT is_synthetic_activity
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'The generated business activity must remain labeled synthetic.'

    FROM unit_economics
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
    `__PROJECT_ID__.retail_finops_control.unit_economics_data_quality_control`

ORDER BY check_name;


SELECT
    CASE
        WHEN COUNTIF(
            severity = 'ERROR'
            AND check_status = 'FAIL'
        ) > 0
        THEN 'FAIL'

        ELSE 'PASS'
    END AS overall_unit_economics_data_quality_status,

    COUNTIF(
        severity = 'ERROR'
        AND check_status = 'FAIL'
    ) AS failed_error_checks

FROM
    `__PROJECT_ID__.retail_finops_control.unit_economics_data_quality_control`;

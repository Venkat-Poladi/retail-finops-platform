/*
Purpose:
    Validate the structural and financial integrity of the allocation output.

Grain:
    One row per allocation quality check.

Source:
    retail_finops_core.fct_cloud_cost
    retail_finops_core.fct_cost_allocation

Key controls:
    - Allocation IDs are complete and unique.
    - Every fact record has allocation output.
    - Direct and unallocated records create exactly one row.
    - Shared weights sum to 1.
    - Allocation costs reconcile by source record.
    - Credits and refunds retain their sign.
    - Allocated targets contain ownership.
    - No source record uses multiple allocation methods.

Owner:
    FinOps

Refresh:
    After allocation reconciliation.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.allocation_data_quality_control`

AS

WITH allocation_rows AS (
    SELECT
        *

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
),

fact_rows AS (
    SELECT
        record_id,
        billed_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
),

allocation_by_record AS (
    SELECT
        record_id,

        COUNT(*) AS allocation_row_count,

        COUNT(DISTINCT allocation_method)
            AS allocation_method_count,

        MIN(source_billed_cost)
            AS minimum_source_billed_cost,

        MAX(source_billed_cost)
            AS maximum_source_billed_cost,

        SUM(allocated_cost)
            AS allocated_cost_total,

        MIN(allocation_weight)
            AS minimum_allocation_weight,

        MAX(allocation_weight)
            AS maximum_allocation_weight

    FROM allocation_rows

    GROUP BY record_id
),

shared_weight_by_record AS (
    SELECT
        record_id,

        COUNT(*) AS shared_allocation_rows,

        SUM(allocation_weight)
            AS shared_weight_total

    FROM allocation_rows

    WHERE allocation_method = 'SHARED_PROPORTIONAL'

    GROUP BY record_id
),

quality_checks AS (

    /* 1. Null allocation ID */
    SELECT
        'NULL_ALLOCATION_ID'
            AS check_name,

        'ERROR'
            AS severity,

        COUNTIF(allocation_id IS NULL OR allocation_id = '')
            AS issue_count,

        CASE
            WHEN COUNTIF(
                allocation_id IS NULL
                OR allocation_id = ''
            ) = 0
            THEN 'PASS'

            ELSE 'FAIL'
        END AS check_status,

        'Every allocation row must have an allocation_id.'
            AS check_description

    FROM allocation_rows

    UNION ALL

    /* 2. Duplicate allocation ID */
    SELECT
        'DUPLICATE_ALLOCATION_ID',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'allocation_id must be unique.'

    FROM (
        SELECT
            allocation_id

        FROM allocation_rows

        WHERE allocation_id IS NOT NULL

        GROUP BY allocation_id

        HAVING COUNT(*) > 1
    )

    UNION ALL

    /* 3. Null source record ID */
    SELECT
        'NULL_RECORD_ID',
        'ERROR',

        COUNTIF(record_id IS NULL OR record_id = ''),

        CASE
            WHEN COUNTIF(
                record_id IS NULL
                OR record_id = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every allocation row must retain source record_id.'

    FROM allocation_rows

    UNION ALL

    /* 4. Fact records without allocation */
    SELECT
        'FACT_RECORD_WITHOUT_ALLOCATION',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every fact record must have at least one allocation row.'

    FROM fact_rows AS fact

    LEFT JOIN (
        SELECT DISTINCT
            record_id

        FROM allocation_rows
    ) AS allocation

        USING (record_id)

    WHERE allocation.record_id IS NULL

    UNION ALL

    /* 5. Allocation records without fact parent */
    SELECT
        'ALLOCATION_WITHOUT_FACT_RECORD',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every allocation record must link to fct_cloud_cost.'

    FROM (
        SELECT DISTINCT
            record_id

        FROM allocation_rows
    ) AS allocation

    LEFT JOIN fact_rows AS fact
        USING (record_id)

    WHERE fact.record_id IS NULL

    UNION ALL

    /* 6. Direct records must create exactly one row */
    SELECT
        'DIRECT_RECORD_ROW_COUNT',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'DIRECT records must create exactly one allocation row.'

    FROM (
        SELECT
            record_id

        FROM allocation_rows

        WHERE allocation_method = 'DIRECT'

        GROUP BY record_id

        HAVING COUNT(*) <> 1
    )

    UNION ALL

    /* 7. Unallocated records must create exactly one row */
    SELECT
        'UNALLOCATED_RECORD_ROW_COUNT',
        'ERROR',

        COUNT(*),

        CASE
            WHEN COUNT(*) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'UNALLOCATED records must create exactly one allocation row.'

    FROM (
        SELECT
            record_id

        FROM allocation_rows

        WHERE allocation_method = 'UNALLOCATED'

        GROUP BY record_id

        HAVING COUNT(*) <> 1
    )

    UNION ALL

    /* 8. Direct weight must equal 1 */
    SELECT
        'DIRECT_WEIGHT_NOT_ONE',
        'ERROR',

        COUNTIF(
            allocation_method = 'DIRECT'
            AND ABS(allocation_weight - 1) > 0.000001
        ),

        CASE
            WHEN COUNTIF(
                allocation_method = 'DIRECT'
                AND ABS(allocation_weight - 1)
                    > 0.000001
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'DIRECT allocation weight must equal 1.'

    FROM allocation_rows

    UNION ALL

    /* 9. Unallocated weight must equal 1 */
    SELECT
        'UNALLOCATED_WEIGHT_NOT_ONE',
        'ERROR',

        COUNTIF(
            allocation_method = 'UNALLOCATED'
            AND ABS(allocation_weight - 1) > 0.000001
        ),

        CASE
            WHEN COUNTIF(
                allocation_method = 'UNALLOCATED'
                AND ABS(allocation_weight - 1)
                    > 0.000001
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'UNALLOCATED allocation weight must equal 1.'

    FROM allocation_rows

    UNION ALL

    /* 10. Shared weights must sum to 1 */
    SELECT
        'SHARED_WEIGHT_TOTAL_NOT_ONE',
        'ERROR',

        COUNTIF(
            ABS(shared_weight_total - 1)
                > 0.000001
        ),

        CASE
            WHEN COUNTIF(
                ABS(shared_weight_total - 1)
                    > 0.000001
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Shared allocation weights must total 1 per source record.'

    FROM shared_weight_by_record

    UNION ALL

    /* 11. Weight range */
    SELECT
        'ALLOCATION_WEIGHT_OUT_OF_RANGE',
        'ERROR',

        COUNTIF(
            allocation_weight < 0
            OR allocation_weight > 1
            OR allocation_weight IS NULL
        ),

        CASE
            WHEN COUNTIF(
                allocation_weight < 0
                OR allocation_weight > 1
                OR allocation_weight IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Allocation weights must be between 0 and 1.'

    FROM allocation_rows

    UNION ALL

    /* 12. Multiple methods on one record */
    SELECT
        'MULTIPLE_METHODS_PER_RECORD',
        'ERROR',

        COUNTIF(allocation_method_count > 1),

        CASE
            WHEN COUNTIF(
                allocation_method_count > 1
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'A source record cannot use more than one allocation method.'

    FROM allocation_by_record

    UNION ALL

    /* 13. Missing allocated target */
    SELECT
        'ALLOCATED_TARGET_MISSING',
        'ERROR',

        COUNTIF(
            allocation_status = 'ALLOCATED'
            AND (
                target_application_name IS NULL
                OR TRIM(target_application_name) = ''
                OR target_department_name IS NULL
                OR TRIM(target_department_name) = ''
                OR target_cost_center IS NULL
                OR TRIM(target_cost_center) = ''
            )
        ),

        CASE
            WHEN COUNTIF(
                allocation_status = 'ALLOCATED'
                AND (
                    target_application_name IS NULL
                    OR TRIM(target_application_name) = ''
                    OR target_department_name IS NULL
                    OR TRIM(target_department_name) = ''
                    OR target_cost_center IS NULL
                    OR TRIM(target_cost_center) = ''
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Allocated rows require application, department and cost center.'

    FROM allocation_rows

    UNION ALL

    /* 14. Unallocated target must be explicit */
    SELECT
        'UNALLOCATED_TARGET_NOT_EXPLICIT',
        'ERROR',

        COUNTIF(
            allocation_method = 'UNALLOCATED'
            AND (
                target_application_name <> 'Unallocated'
                OR target_department_name <> 'Unallocated'
                OR target_cost_center <> 'Unallocated'
            )
        ),

        CASE
            WHEN COUNTIF(
                allocation_method = 'UNALLOCATED'
                AND (
                    target_application_name <> 'Unallocated'
                    OR target_department_name <> 'Unallocated'
                    OR target_cost_center <> 'Unallocated'
                )
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Unallocated cost must remain visibly labeled Unallocated.'

    FROM allocation_rows

    UNION ALL

    /* 15. Source-record financial mismatch */
    SELECT
        'SOURCE_RECORD_COST_MISMATCH',
        'ERROR',

        COUNTIF(
            ABS(
                allocated_cost_total
                    - minimum_source_billed_cost
            ) > 0.01
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    allocated_cost_total
                        - minimum_source_billed_cost
                ) > 0.01
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Allocated child rows must sum to source billed cost.'

    FROM allocation_by_record

    UNION ALL

    /* 16. Source cost inconsistent across children */
    SELECT
        'INCONSISTENT_SOURCE_COST_ON_CHILDREN',
        'ERROR',

        COUNTIF(
            ABS(
                maximum_source_billed_cost
                    - minimum_source_billed_cost
            ) > 0.000001
        ),

        CASE
            WHEN COUNTIF(
                ABS(
                    maximum_source_billed_cost
                        - minimum_source_billed_cost
                ) > 0.000001
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'All child rows for one record must carry the same source cost.'

    FROM allocation_by_record

    UNION ALL

    /* 17. Credit/refund sign changed */
    SELECT
        'NEGATIVE_COST_SIGN_CHANGED',
        'ERROR',

        COUNTIF(
            fact.billed_cost < 0
            AND allocation.allocated_cost_total > 0.01
        ),

        CASE
            WHEN COUNTIF(
                fact.billed_cost < 0
                AND allocation.allocated_cost_total
                    > 0.01
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Negative credits and refunds must remain negative.'

    FROM fact_rows AS fact

    INNER JOIN allocation_by_record AS allocation
        USING (record_id)

    UNION ALL

    /* 18. Positive cost sign changed */
    SELECT
        'POSITIVE_COST_SIGN_CHANGED',
        'ERROR',

        COUNTIF(
            fact.billed_cost > 0
            AND allocation.allocated_cost_total < -0.01
        ),

        CASE
            WHEN COUNTIF(
                fact.billed_cost > 0
                AND allocation.allocated_cost_total
                    < -0.01
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Positive billed cost must not become negative.'

    FROM fact_rows AS fact

    INNER JOIN allocation_by_record AS allocation
        USING (record_id)

    UNION ALL

    /* 19. Unsupported allocation method */
    SELECT
        'UNSUPPORTED_ALLOCATION_METHOD',
        'ERROR',

        COUNTIF(
            allocation_method NOT IN (
                'DIRECT',
                'SHARED_PROPORTIONAL',
                'UNALLOCATED'
            )
            OR allocation_method IS NULL
        ),

        CASE
            WHEN COUNTIF(
                allocation_method NOT IN (
                    'DIRECT',
                    'SHARED_PROPORTIONAL',
                    'UNALLOCATED'
                )
                OR allocation_method IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Only approved allocation methods are permitted.'

    FROM allocation_rows

    UNION ALL

    /* 20. Missing lineage */
    SELECT
        'MISSING_ALLOCATION_LINEAGE',
        'ERROR',

        COUNTIF(
            pipeline_run_id IS NULL
            OR TRIM(pipeline_run_id) = ''
            OR source_system IS NULL
            OR TRIM(source_system) = ''
            OR source_file IS NULL
            OR TRIM(source_file) = ''
            OR source_record_id IS NULL
            OR TRIM(source_record_id) = ''
        ),

        CASE
            WHEN COUNTIF(
                pipeline_run_id IS NULL
                OR TRIM(pipeline_run_id) = ''
                OR source_system IS NULL
                OR TRIM(source_system) = ''
                OR source_file IS NULL
                OR TRIM(source_file) = ''
                OR source_record_id IS NULL
                OR TRIM(source_record_id) = ''
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Allocation rows must retain complete source lineage.'

    FROM allocation_rows

    UNION ALL

    /* 21. Null allocated cost */
    SELECT
        'NULL_ALLOCATED_COST',
        'ERROR',

        COUNTIF(allocated_cost IS NULL),

        CASE
            WHEN COUNTIF(
                allocated_cost IS NULL
            ) = 0
            THEN 'PASS'
            ELSE 'FAIL'
        END,

        'Every allocation row must have allocated_cost.'

    FROM allocation_rows

    UNION ALL

    /* 22. Shared rows without a usable driver */
    SELECT
        'SHARED_RECORD_WITHOUT_DRIVER',
        'WARNING',

        COUNTIF(
            allocation_rule_id = 'SHARED_NO_DRIVER'
        ),

        CASE
            WHEN COUNTIF(
                allocation_rule_id = 'SHARED_NO_DRIVER'
            ) = 0
            THEN 'PASS'
            ELSE 'PASS_WITH_EXPECTED_EXCEPTIONS'
        END,

        'Shared rows without driver support remain explicitly unallocated.'

    FROM allocation_rows
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
    `__PROJECT_ID__.retail_finops_control.allocation_data_quality_control`

ORDER BY
    CASE severity
        WHEN 'ERROR' THEN 1
        WHEN 'WARNING' THEN 2
        ELSE 3
    END,
    check_name;


SELECT
    CASE
        WHEN COUNTIF(
            severity = 'ERROR'
            AND check_status = 'FAIL'
        ) > 0
        THEN 'FAIL'

        WHEN COUNTIF(
            severity = 'WARNING'
            AND issue_count > 0
        ) > 0
        THEN 'PASS_WITH_EXPECTED_EXCEPTIONS'

        ELSE 'PASS'
    END AS overall_allocation_data_quality_status,

    COUNTIF(
        severity = 'ERROR'
        AND check_status = 'FAIL'
    ) AS failed_error_checks,

    COUNTIF(
        severity = 'WARNING'
        AND issue_count > 0
    ) AS warning_checks_with_issues

FROM
    `__PROJECT_ID__.retail_finops_control.allocation_data_quality_control`;

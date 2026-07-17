/*
Purpose:
    Measure allocation coverage before and after shared-cost allocation.

Grain:
    One row per provider plus one all-cloud row.

Source:
    retail_finops_core.fct_cloud_cost
    retail_finops_core.fct_cost_allocation

Key controls:
    - Coverage uses positive Usage cost only.
    - Direct coverage measures source attribution.
    - Post-allocation coverage includes shared proportional allocation.
    - Unallocated cost remains visible.
    - Actual coverage is compared honestly with the 95% target.

Owner:
    FinOps

Refresh:
    After fct_cost_allocation refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_control.allocation_health_control`

AS

WITH positive_usage_allocation AS (
    SELECT
        fact.provider_name,
        fact.record_id,

        allocation.allocation_method,
        allocation.allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
            AS fact

    INNER JOIN
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
            AS allocation

        ON fact.record_id = allocation.record_id

    WHERE UPPER(fact.charge_category) = 'USAGE'
      AND fact.billed_cost > 0
),

provider_health AS (
    SELECT
        provider_name,

        SUM(allocated_cost)
            AS total_positive_usage_cost,

        SUM(
            CASE
                WHEN allocation_method = 'DIRECT'
                THEN allocated_cost
                ELSE 0
            END
        ) AS directly_allocated_cost,

        SUM(
            CASE
                WHEN allocation_method
                    = 'SHARED_PROPORTIONAL'
                THEN allocated_cost
                ELSE 0
            END
        ) AS shared_allocated_cost,

        SUM(
            CASE
                WHEN allocation_method = 'UNALLOCATED'
                THEN allocated_cost
                ELSE 0
            END
        ) AS unallocated_cost

    FROM positive_usage_allocation

    GROUP BY provider_name
),

all_cloud_health AS (
    SELECT
        'ALL_CLOUD' AS provider_name,

        SUM(total_positive_usage_cost)
            AS total_positive_usage_cost,

        SUM(directly_allocated_cost)
            AS directly_allocated_cost,

        SUM(shared_allocated_cost)
            AS shared_allocated_cost,

        SUM(unallocated_cost)
            AS unallocated_cost

    FROM provider_health
),

combined_health AS (
    SELECT
        *

    FROM provider_health

    UNION ALL

    SELECT
        *

    FROM all_cloud_health
)

SELECT
    provider_name,

    ROUND(
        total_positive_usage_cost,
        6
    ) AS total_positive_usage_cost,

    ROUND(
        directly_allocated_cost,
        6
    ) AS directly_allocated_cost,

    ROUND(
        shared_allocated_cost,
        6
    ) AS shared_allocated_cost,

    ROUND(
        unallocated_cost,
        6
    ) AS unallocated_cost,

    SAFE_DIVIDE(
        directly_allocated_cost,
        total_positive_usage_cost
    ) AS before_allocation_coverage_pct,

    SAFE_DIVIDE(
        directly_allocated_cost
            + shared_allocated_cost,
        total_positive_usage_cost
    ) AS after_allocation_coverage_pct,

    SAFE_DIVIDE(
        unallocated_cost,
        total_positive_usage_cost
    ) AS unallocated_cost_pct,

    (
        SAFE_DIVIDE(
            directly_allocated_cost
                + shared_allocated_cost,
            total_positive_usage_cost
        )
        -
        SAFE_DIVIDE(
            directly_allocated_cost,
            total_positive_usage_cost
        )
    ) * 100 AS coverage_change_pp,

    CAST(0.95 AS NUMERIC)
        AS target_coverage_pct,

    CASE
        WHEN SAFE_DIVIDE(
            directly_allocated_cost
                + shared_allocated_cost,
            total_positive_usage_cost
        ) > 0.95
        THEN 'TARGET_MET'

        ELSE 'TARGET_MISSED'
    END AS target_status,

    CURRENT_TIMESTAMP()
        AS control_timestamp

FROM combined_health;


SELECT
    provider_name,

    total_positive_usage_cost,
    directly_allocated_cost,
    shared_allocated_cost,
    unallocated_cost,

    ROUND(
        before_allocation_coverage_pct * 100,
        2
    ) AS before_allocation_coverage_percent,

    ROUND(
        after_allocation_coverage_pct * 100,
        2
    ) AS after_allocation_coverage_percent,

    ROUND(
        unallocated_cost_pct * 100,
        2
    ) AS unallocated_cost_percent,

    ROUND(
        coverage_change_pp,
        2
    ) AS coverage_change_percentage_points,

    target_status

FROM
    `__PROJECT_ID__.retail_finops_control.allocation_health_control`

ORDER BY
    CASE
        WHEN provider_name = 'ALL_CLOUD'
        THEN 2
        ELSE 1
    END,
    provider_name;
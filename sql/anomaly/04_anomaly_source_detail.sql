/*
Purpose:
    Link each detected anomaly to its contributing fact-table records.

Grain:
    One row per anomaly and contributing source fact record.

Source:
    retail_finops_mart.fct_cost_anomaly
    retail_finops_core.fct_cloud_cost

Key controls:
    - Every anomaly traces to approved fact records.
    - Contributions include positive Usage cost only.
    - Contribution totals reconcile to anomaly actual cost.
    - Full source and pipeline lineage remains available.

Owner:
    FinOps Analytics.

Refresh:
    After fct_cost_anomaly refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_anomaly_source_detail`

PARTITION BY anomaly_date

CLUSTER BY
    anomaly_id,
    provider_name,
    record_id

AS

SELECT
    anomaly.anomaly_id,
    anomaly.anomaly_date,

    fact.record_id,
    fact.parent_record_id,
    fact.source_record_id,
    fact.pipeline_run_id,
    fact.source_system,
    fact.source_file,
    fact.ingestion_timestamp,

    fact.provider_name,
    fact.billing_account_id,
    fact.sub_account_id,
    fact.project_id,

    COALESCE(
        NULLIF(TRIM(fact.application_name), ''),
        'Unallocated'
    ) AS application_name,

    COALESCE(
        NULLIF(TRIM(fact.department_name), ''),
        'Unallocated'
    ) AS department_name,

    COALESCE(
        NULLIF(TRIM(fact.environment_name), ''),
        'Unallocated'
    ) AS environment_name,

    COALESCE(
        NULLIF(TRIM(fact.cost_center), ''),
        'Unallocated'
    ) AS cost_center,

    COALESCE(
        NULLIF(TRIM(fact.owner_name), ''),
        'FinOps Lead'
    ) AS owner_name,

    fact.service_category,
    fact.service_name,

    COALESCE(
        NULLIF(TRIM(fact.resource_id), ''),
        'UNKNOWN_RESOURCE'
    ) AS resource_id,

    COALESCE(
        NULLIF(TRIM(fact.resource_name), ''),
        'Unknown Resource'
    ) AS resource_name,

    COALESCE(
        NULLIF(TRIM(fact.region_name), ''),
        'global'
    ) AS region_name,

    fact.charge_category,
    fact.charge_class,
    fact.pricing_category,

    fact.consumed_quantity,
    fact.consumed_unit,

    fact.billed_cost
        AS contribution_cost,

    CAST(
        SAFE_DIVIDE(
            fact.billed_cost,
            anomaly.actual_cost
        )
        AS NUMERIC
    ) AS contribution_pct,

    fact.billing_currency,

    fact.is_synthetic,
    fact.is_late_arriving,
    fact.data_status,

    CURRENT_TIMESTAMP()
        AS data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_mart.fct_cost_anomaly`
        AS anomaly

INNER JOIN
    `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
        AS fact

    ON DATE(fact.charge_period_start)
        = anomaly.anomaly_date

   AND fact.provider_name
        = anomaly.provider_name

   AND COALESCE(
        NULLIF(TRIM(fact.billing_account_id), ''),
        'UNKNOWN_BILLING_ACCOUNT'
       )
        = anomaly.billing_account_id

   AND COALESCE(
        NULLIF(TRIM(fact.sub_account_id), ''),
        'UNKNOWN_SUB_ACCOUNT'
       )
        = anomaly.sub_account_id

   AND COALESCE(
        NULLIF(TRIM(fact.project_id), ''),
        'NOT_APPLICABLE'
       )
        = anomaly.project_id

   AND COALESCE(
        NULLIF(TRIM(fact.application_name), ''),
        'Unallocated'
       )
        = anomaly.application_name

   AND COALESCE(
        NULLIF(TRIM(fact.department_name), ''),
        'Unallocated'
       )
        = anomaly.department_name

   AND COALESCE(
        NULLIF(TRIM(fact.environment_name), ''),
        'Unallocated'
       )
        = anomaly.environment_name

   AND COALESCE(
        NULLIF(TRIM(fact.cost_center), ''),
        'Unallocated'
       )
        = anomaly.cost_center

   AND COALESCE(
        NULLIF(TRIM(fact.owner_name), ''),
        'FinOps Lead'
       )
        = anomaly.owner_name

   AND COALESCE(
        NULLIF(TRIM(fact.service_name), ''),
        'Unknown Service'
       )
        = anomaly.service_name

   AND COALESCE(
        NULLIF(TRIM(fact.resource_id), ''),
        'UNKNOWN_RESOURCE'
       )
        = anomaly.resource_id

   AND COALESCE(
        NULLIF(TRIM(fact.region_name), ''),
        'global'
       )
        = anomaly.region_name

   AND fact.billing_currency
        = anomaly.billing_currency

WHERE UPPER(fact.charge_category) = 'USAGE'
  AND fact.billed_cost > 0;

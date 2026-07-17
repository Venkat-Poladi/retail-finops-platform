/*
Purpose:
    Transform provider-specific GCP raw billing records into the common
    FOCUS-aligned staging schema.

Grain:
    One parent charge row per GCP source record, plus one child row for
    each element in the source credits[] array.

Source:
    finops-learning-lab.retail_finops_raw.raw_gcp_billing

Key controls:
    - Preserve billing account and project as different hierarchy levels.
    - Extract labels with scalar subqueries so the parent cost is not multiplied.
    - Expand credits separately and link them to the parent charge.
    - Preserve duplicate source rows and mark one deterministic canonical row.
    - Keep monetary fields as BigQuery NUMERIC.
    - Do not combine GCP with AWS until after provider-specific conformance.

Owner:
    FinOps Analytics.

Refresh:
    Rebuilt after each approved GCP raw ingestion.
*/

CREATE OR REPLACE TABLE
    `finops-learning-lab.retail_finops_staging.stg_gcp_focus`

PARTITION BY DATE(charge_period_start)

CLUSTER BY
    billing_account_id,
    service_name,
    application_name,
    charge_category

AS

WITH source_rows AS (
    SELECT
        raw.raw_row_id,
        raw.pipeline_run_id,
        raw.source_file,
        raw.ingestion_timestamp,

        CAST(raw.source_record_id AS STRING) AS source_record_id,
        CAST(raw.billing_account_id AS STRING) AS billing_account_id,
        raw.project,
        raw.invoice,
        raw.usage_start_time,
        raw.usage_end_time,
        raw.service,
        raw.sku,
        raw.resource,
        raw.location,
        raw.usage,
        raw.price,
        raw.consumption_model,
        raw.credits,

        CAST(raw.cost_type AS STRING) AS cost_type,
        SAFE_CAST(raw.cost_at_list AS NUMERIC) AS cost_at_list,
        SAFE_CAST(raw.cost AS NUMERIC) AS cost,
        CAST(raw.currency AS STRING) AS currency,
        CAST(raw.modeled_commitment_profile_id AS STRING)
            AS modeled_commitment_profile_id,

        CAST(raw.is_synthetic AS BOOL) AS is_synthetic,
        CAST(raw.is_late_arriving AS BOOL) AS is_late_arriving,
        CAST(raw.data_quality_status AS STRING) AS data_quality_status,
        CAST(raw.injected_scenario AS STRING) AS injected_scenario,

        (
            SELECT label.value
            FROM UNNEST(raw.labels) AS label
            WHERE LOWER(label.key) = 'application'
            LIMIT 1
        ) AS application_name_value,

        (
            SELECT label.value
            FROM UNNEST(raw.labels) AS label
            WHERE LOWER(label.key) = 'department'
            LIMIT 1
        ) AS department_name_value,

        (
            SELECT label.value
            FROM UNNEST(raw.labels) AS label
            WHERE LOWER(label.key) = 'environment'
            LIMIT 1
        ) AS environment_name_value,

        (
            SELECT label.value
            FROM UNNEST(raw.labels) AS label
            WHERE LOWER(label.key) = 'cost_center'
            LIMIT 1
        ) AS cost_center_value,

        (
            SELECT label.value
            FROM UNNEST(raw.labels) AS label
            WHERE LOWER(label.key) IN ('owner', 'team')
            ORDER BY
                CASE WHEN LOWER(label.key) = 'owner' THEN 1 ELSE 2 END
            LIMIT 1
        ) AS owner_name_value

    FROM
        `finops-learning-lab.retail_finops_raw.raw_gcp_billing` AS raw
),

ranked_source_rows AS (
    SELECT
        source_rows.*,

        COUNT(*) OVER (
            PARTITION BY source_record_id
        ) > 1 AS is_duplicate,

        ROW_NUMBER() OVER (
            PARTITION BY source_record_id
            ORDER BY
                ingestion_timestamp,
                raw_row_id
        ) AS duplicate_rank

    FROM
        source_rows
),

parent_rows AS (
    SELECT
        CONCAT('GCP-PARENT-', source_record_id) AS record_id,
        CAST(NULL AS STRING) AS parent_record_id,
        source_record_id,
        pipeline_run_id,
        'GCP_BILLING_EXPORT' AS source_system,
        source_file,
        ingestion_timestamp,
        '1.2' AS focus_spec_version,
        is_synthetic,
        is_late_arriving,

        PARSE_DATE(
            '%Y%m%d',
            CONCAT(CAST(invoice.month AS STRING), '01')
        ) AS billing_period_start,

        DATE_ADD(
            PARSE_DATE(
                '%Y%m%d',
                CONCAT(CAST(invoice.month AS STRING), '01')
            ),
            INTERVAL 1 MONTH
        ) AS billing_period_end,

        CAST(usage_start_time AS TIMESTAMP) AS charge_period_start,
        CAST(usage_end_time AS TIMESTAMP) AS charge_period_end,
        CONCAT('GCP-', CAST(invoice.month AS STRING)) AS invoice_id,
        currency AS billing_currency,

        'GCP' AS provider_name,
        billing_account_id,
        CAST(NULL AS STRING) AS billing_account_name,
        CAST(project.id AS STRING) AS sub_account_id,
        CAST(project.name AS STRING) AS sub_account_name,
        'GCP_PROJECT' AS sub_account_type,
        CAST(project.id AS STRING) AS project_id,

        CASE CAST(service.description AS STRING)
            WHEN 'Compute Engine' THEN 'Compute'
            WHEN 'Cloud Run' THEN 'Serverless'
            WHEN 'Cloud SQL' THEN 'Database'
            WHEN 'Cloud Storage' THEN 'Storage'
            WHEN 'Cloud Logging' THEN 'Observability'
            WHEN 'Network Services' THEN 'Network'
            WHEN 'Vertex AI' THEN 'AI'
            WHEN 'Google Cloud Marketplace' THEN 'Marketplace'
            WHEN 'Google Cloud Billing' THEN 'Other'
            ELSE 'Other'
        END AS service_category,

        CAST(service.description AS STRING) AS service_name,
        CAST(sku.id AS STRING) AS sku_id,
        CAST(sku.description AS STRING) AS sku_name,
        CAST(resource.global_name AS STRING) AS resource_id,
        CAST(resource.name AS STRING) AS resource_name,
        CAST(location.region AS STRING) AS region_name,
        NULLIF(CAST(location.zone AS STRING), '') AS availability_zone,

        CASE
            WHEN cost_type = 'tax'
                THEN 'Tax'
            WHEN cost_type IN ('adjustment', 'rounding_error')
                THEN 'Adjustment'
            WHEN injected_scenario IN (
                'modeled_cud_fee',
                'marketplace_subscription'
            )
                THEN 'Purchase'
            ELSE 'Usage'
        END AS charge_category,

        CASE
            WHEN injected_scenario IN (
                'modeled_cud_fee',
                'marketplace_subscription'
            )
                THEN injected_scenario
            ELSE cost_type
        END AS charge_class,

        CASE
            WHEN injected_scenario IN (
                'modeled_cud_fee',
                'marketplace_subscription'
            )
                THEN 'Recurring'
            WHEN cost_type IN ('tax', 'adjustment', 'rounding_error')
                THEN 'One-Time'
            ELSE 'Usage-Based'
        END AS charge_frequency,

        CASE
            WHEN NULLIF(modeled_commitment_profile_id, '') IS NOT NULL
                THEN 'Commitment Discount'
            WHEN injected_scenario = 'marketplace_subscription'
                THEN 'Other'
            WHEN cost_type = 'regular'
                THEN 'On-Demand'
            ELSE 'Other'
        END AS pricing_category,

        NULLIF(modeled_commitment_profile_id, '')
            AS commitment_discount_id,

        CASE
            WHEN LOWER(CAST(consumption_model.id AS STRING))
                    LIKE '%flexiblecud%'
                THEN 'Flexible CUD'
            WHEN LOWER(CAST(consumption_model.id AS STRING))
                    LIKE '%computecud%'
                THEN 'Compute CUD'
            WHEN LOWER(CAST(consumption_model.id AS STRING))
                    LIKE '%resourcecud%'
                THEN 'Resource CUD'
            ELSE CAST(NULL AS STRING)
        END AS commitment_discount_type,

        CASE
            WHEN LOWER(modeled_commitment_profile_id) LIKE '%over%'
                THEN 'Underutilized'
            WHEN LOWER(modeled_commitment_profile_id) LIKE '%under%'
                THEN 'Undercovered'
            WHEN LOWER(modeled_commitment_profile_id) LIKE '%balanced%'
                THEN 'Balanced'
            WHEN NULLIF(modeled_commitment_profile_id, '') IS NOT NULL
                THEN 'Modeled'
            ELSE CAST(NULL AS STRING)
        END AS commitment_discount_status,

        COALESCE(cost_at_list, NUMERIC '0') AS list_cost,
        COALESCE(cost, NUMERIC '0') AS contracted_cost,
        COALESCE(cost, NUMERIC '0') AS billed_cost,
        COALESCE(cost, NUMERIC '0') AS effective_cost,
        SAFE_CAST(usage.amount AS NUMERIC) AS consumed_quantity,
        NULLIF(CAST(usage.unit AS STRING), '') AS consumed_unit,

        NULLIF(application_name_value, '') AS application_name,
        NULLIF(department_name_value, '') AS department_name,
        NULLIF(environment_name_value, '') AS environment_name,
        NULLIF(cost_center_value, '') AS cost_center,
        NULLIF(owner_name_value, '') AS owner_name,

        CASE
            WHEN NULLIF(application_name_value, '') IS NULL
              OR NULLIF(department_name_value, '') IS NULL
              OR NULLIF(environment_name_value, '') IS NULL
              OR NULLIF(cost_center_value, '') IS NULL
                THEN 'Unallocated'
            ELSE 'Direct'
        END AS allocation_status,

        is_duplicate,
        CAST(duplicate_rank AS INT64) AS duplicate_rank,
        duplicate_rank = 1 AS is_canonical_record,

        (
            duplicate_rank = 1
            AND data_quality_status <> 'INVALID_NEGATIVE_USAGE'
        ) AS is_valid_for_financial_reporting,

        CASE
            WHEN duplicate_rank > 1
                THEN 'DUPLICATE_SOURCE_RECORD'
            WHEN data_quality_status <> 'VALID'
                THEN data_quality_status
            ELSE CAST(NULL AS STRING)
        END AS data_quality_reason,

        CAST(NULL AS STRING) AS x_aws_line_item_type,
        cost_type AS x_gcp_cost_type,
        CAST(NULL AS STRING) AS x_credit_type,
        data_quality_status AS x_source_record_status

    FROM
        ranked_source_rows
),

credit_rows AS (
    SELECT
        CONCAT(
            'GCP-CREDIT-',
            source_record_id,
            '-',
            CAST(credit_offset AS STRING)
        ) AS record_id,

        CONCAT('GCP-PARENT-', source_record_id) AS parent_record_id,
        source_record_id,
        pipeline_run_id,
        'GCP_BILLING_EXPORT' AS source_system,
        source_file,
        ingestion_timestamp,
        '1.2' AS focus_spec_version,
        is_synthetic,
        is_late_arriving,

        PARSE_DATE(
            '%Y%m%d',
            CONCAT(CAST(invoice.month AS STRING), '01')
        ) AS billing_period_start,

        DATE_ADD(
            PARSE_DATE(
                '%Y%m%d',
                CONCAT(CAST(invoice.month AS STRING), '01')
            ),
            INTERVAL 1 MONTH
        ) AS billing_period_end,

        CAST(usage_start_time AS TIMESTAMP) AS charge_period_start,
        CAST(usage_end_time AS TIMESTAMP) AS charge_period_end,
        CONCAT('GCP-', CAST(invoice.month AS STRING)) AS invoice_id,
        currency AS billing_currency,

        'GCP' AS provider_name,
        billing_account_id,
        CAST(NULL AS STRING) AS billing_account_name,
        CAST(project.id AS STRING) AS sub_account_id,
        CAST(project.name AS STRING) AS sub_account_name,
        'GCP_PROJECT' AS sub_account_type,
        CAST(project.id AS STRING) AS project_id,

        CASE CAST(service.description AS STRING)
            WHEN 'Compute Engine' THEN 'Compute'
            WHEN 'Cloud Run' THEN 'Serverless'
            WHEN 'Cloud SQL' THEN 'Database'
            WHEN 'Cloud Storage' THEN 'Storage'
            WHEN 'Cloud Logging' THEN 'Observability'
            WHEN 'Network Services' THEN 'Network'
            WHEN 'Vertex AI' THEN 'AI'
            WHEN 'Google Cloud Marketplace' THEN 'Marketplace'
            WHEN 'Google Cloud Billing' THEN 'Other'
            ELSE 'Other'
        END AS service_category,

        CAST(service.description AS STRING) AS service_name,
        CAST(sku.id AS STRING) AS sku_id,
        CAST(credit.full_name AS STRING) AS sku_name,
        CAST(resource.global_name AS STRING) AS resource_id,
        CAST(resource.name AS STRING) AS resource_name,
        CAST(location.region AS STRING) AS region_name,
        NULLIF(CAST(location.zone AS STRING), '') AS availability_zone,

        'Credit' AS charge_category,
        CAST(credit.type AS STRING) AS charge_class,
        'One-Time' AS charge_frequency,

        CASE
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
                THEN 'Commitment Discount'
            ELSE 'Discount'
        END AS pricing_category,

        NULLIF(modeled_commitment_profile_id, '')
            AS commitment_discount_id,

        CASE
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
             AND LOWER(CAST(consumption_model.id AS STRING))
                    LIKE '%flexiblecud%'
                THEN 'Flexible CUD'
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
             AND LOWER(CAST(consumption_model.id AS STRING))
                    LIKE '%computecud%'
                THEN 'Compute CUD'
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
             AND LOWER(CAST(consumption_model.id AS STRING))
                    LIKE '%resourcecud%'
                THEN 'Resource CUD'
            ELSE CAST(NULL AS STRING)
        END AS commitment_discount_type,

        CASE
            WHEN LOWER(modeled_commitment_profile_id) LIKE '%over%'
                THEN 'Underutilized'
            WHEN LOWER(modeled_commitment_profile_id) LIKE '%under%'
                THEN 'Undercovered'
            WHEN LOWER(modeled_commitment_profile_id) LIKE '%balanced%'
                THEN 'Balanced'
            WHEN NULLIF(modeled_commitment_profile_id, '') IS NOT NULL
                THEN 'Modeled'
            ELSE CAST(NULL AS STRING)
        END AS commitment_discount_status,

        NUMERIC '0' AS list_cost,
        SAFE_CAST(credit.amount AS NUMERIC) AS contracted_cost,
        SAFE_CAST(credit.amount AS NUMERIC) AS billed_cost,
        SAFE_CAST(credit.amount AS NUMERIC) AS effective_cost,
        NUMERIC '0' AS consumed_quantity,
        CAST(NULL AS STRING) AS consumed_unit,

        NULLIF(application_name_value, '') AS application_name,
        NULLIF(department_name_value, '') AS department_name,
        NULLIF(environment_name_value, '') AS environment_name,
        NULLIF(cost_center_value, '') AS cost_center,
        NULLIF(owner_name_value, '') AS owner_name,

        CASE
            WHEN NULLIF(application_name_value, '') IS NULL
              OR NULLIF(department_name_value, '') IS NULL
              OR NULLIF(environment_name_value, '') IS NULL
              OR NULLIF(cost_center_value, '') IS NULL
                THEN 'Unallocated'
            ELSE 'Direct'
        END AS allocation_status,

        is_duplicate,
        CAST(duplicate_rank AS INT64) AS duplicate_rank,
        duplicate_rank = 1 AS is_canonical_record,

        (
            duplicate_rank = 1
            AND data_quality_status <> 'INVALID_NEGATIVE_USAGE'
        ) AS is_valid_for_financial_reporting,

        CASE
            WHEN duplicate_rank > 1
                THEN 'DUPLICATE_SOURCE_RECORD'
            WHEN data_quality_status <> 'VALID'
                THEN data_quality_status
            ELSE CAST(NULL AS STRING)
        END AS data_quality_reason,

        CAST(NULL AS STRING) AS x_aws_line_item_type,
        cost_type AS x_gcp_cost_type,
        CAST(credit.type AS STRING) AS x_credit_type,
        data_quality_status AS x_source_record_status

    FROM
        ranked_source_rows

    CROSS JOIN
        UNNEST(credits) AS credit
        WITH OFFSET AS credit_offset
),

conformed_rows AS (
    SELECT
        record_id,
        parent_record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,
        ingestion_timestamp,
        focus_spec_version,
        is_synthetic,
        is_late_arriving,

        billing_period_start,
        billing_period_end,
        charge_period_start,
        charge_period_end,
        invoice_id,
        billing_currency,

        provider_name,
        billing_account_id,
        billing_account_name,
        sub_account_id,
        sub_account_name,
        sub_account_type,
        project_id,

        service_category,
        service_name,
        sku_id,
        sku_name,
        resource_id,
        resource_name,
        region_name,
        availability_zone,

        charge_category,
        charge_class,
        charge_frequency,
        pricing_category,
        commitment_discount_id,
        commitment_discount_type,
        commitment_discount_status,

        list_cost,
        contracted_cost,
        billed_cost,
        effective_cost,
        consumed_quantity,
        consumed_unit,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        allocation_status,

        is_duplicate,
        duplicate_rank,
        is_canonical_record,
        is_valid_for_financial_reporting,
        data_quality_reason,

        x_aws_line_item_type,
        x_gcp_cost_type,
        x_credit_type,
        x_source_record_status

    FROM
        parent_rows

    UNION ALL

    SELECT
        record_id,
        parent_record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,
        ingestion_timestamp,
        focus_spec_version,
        is_synthetic,
        is_late_arriving,

        billing_period_start,
        billing_period_end,
        charge_period_start,
        charge_period_end,
        invoice_id,
        billing_currency,

        provider_name,
        billing_account_id,
        billing_account_name,
        sub_account_id,
        sub_account_name,
        sub_account_type,
        project_id,

        service_category,
        service_name,
        sku_id,
        sku_name,
        resource_id,
        resource_name,
        region_name,
        availability_zone,

        charge_category,
        charge_class,
        charge_frequency,
        pricing_category,
        commitment_discount_id,
        commitment_discount_type,
        commitment_discount_status,

        list_cost,
        contracted_cost,
        billed_cost,
        effective_cost,
        consumed_quantity,
        consumed_unit,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,
        allocation_status,

        is_duplicate,
        duplicate_rank,
        is_canonical_record,
        is_valid_for_financial_reporting,
        data_quality_reason,

        x_aws_line_item_type,
        x_gcp_cost_type,
        x_credit_type,
        x_source_record_status

    FROM
        credit_rows
)

SELECT
    record_id,
    parent_record_id,
    source_record_id,
    pipeline_run_id,
    source_system,
    source_file,
    ingestion_timestamp,
    focus_spec_version,
    is_synthetic,
    is_late_arriving,

    billing_period_start,
    billing_period_end,
    charge_period_start,
    charge_period_end,
    invoice_id,
    billing_currency,

    provider_name,
    billing_account_id,
    billing_account_name,
    sub_account_id,
    sub_account_name,
    sub_account_type,
    project_id,

    service_category,
    service_name,
    sku_id,
    sku_name,
    resource_id,
    resource_name,
    region_name,
    availability_zone,

    charge_category,
    charge_class,
    charge_frequency,
    pricing_category,
    commitment_discount_id,
    commitment_discount_type,
    commitment_discount_status,

    list_cost,
    contracted_cost,
    billed_cost,
    effective_cost,
    consumed_quantity,
    consumed_unit,

    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,
    allocation_status,

    is_duplicate,
    duplicate_rank,
    is_canonical_record,
    is_valid_for_financial_reporting,
    data_quality_reason,

    x_aws_line_item_type,
    x_gcp_cost_type,
    x_credit_type,
    x_source_record_status

FROM
    conformed_rows;
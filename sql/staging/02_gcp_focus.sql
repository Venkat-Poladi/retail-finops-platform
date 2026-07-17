-- Purpose: Normalize GCP BigQuery Billing Export-style JSON rows into the project FOCUS-aligned schema.
-- Grain: One parent row per GCP source record plus one child row per nested credit.
-- Control: Labels are extracted without UNNEST. Credits alone are unnested, preventing row multiplication.

CREATE OR REPLACE TABLE stg_gcp_focus AS
WITH source_ranked AS (
    SELECT
        raw.*,
        COUNT(*) OVER (
            PARTITION BY source_record_id
        ) AS duplicate_count,
        ROW_NUMBER() OVER (
            PARTITION BY source_record_id
            ORDER BY source_row_number
        ) AS duplicate_rank,
        list_extract(
            list_filter(labels, item -> item.key = 'application'),
            1
        ).value AS application_name_value,
        list_extract(
            list_filter(labels, item -> item.key = 'department'),
            1
        ).value AS department_name_value,
        list_extract(
            list_filter(labels, item -> item.key = 'environment'),
            1
        ).value AS environment_name_value,
        list_extract(
            list_filter(labels, item -> item.key = 'cost_center'),
            1
        ).value AS cost_center_value,
        list_extract(
            list_filter(labels, item -> item.key = 'owner'),
            1
        ).value AS owner_name_value
    FROM raw_gcp_billing AS raw
),
parent_rows AS (
    SELECT
        CAST(src.source_record_id AS VARCHAR) AS record_id,
        CAST(NULL AS VARCHAR) AS parent_record_id,
        CAST(src.source_record_id AS VARCHAR) AS source_record_id,
        CAST(src.source_row_number AS BIGINT) AS source_row_number,
        'GCP_BILLING_EXPORT_STYLE' AS source_system,
        'GCP' AS provider_name,
        CAST(src.billing_account_id AS VARCHAR) AS billing_account_id,
        CAST(src.project.id AS VARCHAR) AS sub_account_id,
        CAST(src.project.name AS VARCHAR) AS sub_account_name,
        'GCP_PROJECT' AS sub_account_type,
        CAST(src.project.id AS VARCHAR) AS project_id,
        CAST(strptime(src.invoice.month || '01', '%Y%m%d') AS DATE) AS billing_period_start,
        CAST(
            CAST(strptime(src.invoice.month || '01', '%Y%m%d') AS DATE)
            + INTERVAL 1 MONTH
            AS DATE
        ) AS billing_period_end,
        CAST(src.usage_start_time AS TIMESTAMP) AS charge_period_start,
        CAST(src.usage_end_time AS TIMESTAMP) AS charge_period_end,
        CAST(src.service.description AS VARCHAR) AS service_name,
        CASE CAST(src.service.description AS VARCHAR)
            WHEN 'Compute Engine' THEN 'Compute'
            WHEN 'Cloud Run' THEN 'Serverless'
            WHEN 'Cloud SQL' THEN 'Database'
            WHEN 'Cloud Storage' THEN 'Storage'
            WHEN 'Cloud Logging' THEN 'Observability'
            WHEN 'Network Services' THEN 'Network'
            WHEN 'Vertex AI' THEN 'AI'
            WHEN 'Google Cloud Marketplace' THEN 'Marketplace'
            ELSE 'Other'
        END AS service_category,
        CAST(src.sku.id AS VARCHAR) AS sku_id,
        CAST(src.sku.description AS VARCHAR) AS sku_description,
        CAST(src.resource.global_name AS VARCHAR) AS resource_id,
        CAST(src.location.region AS VARCHAR) AS region_name,
        NULLIF(CAST(src.location.zone AS VARCHAR), '') AS availability_zone,
        CASE
            WHEN src.cost_type = 'tax' THEN 'Tax'
            WHEN src.cost_type IN ('adjustment', 'rounding_error') THEN 'Adjustment'
            WHEN src.injected_scenario IN (
                'modeled_cud_fee',
                'marketplace_subscription'
            ) THEN 'Purchase'
            ELSE 'Usage'
        END AS charge_category,
        CASE
            WHEN src.injected_scenario IN (
                'modeled_cud_fee',
                'marketplace_subscription'
            ) THEN CAST(src.injected_scenario AS VARCHAR)
            ELSE CAST(src.cost_type AS VARCHAR)
        END AS charge_class,
        CASE
            WHEN NULLIF(CAST(src.modeled_commitment_profile_id AS VARCHAR), '') IS NOT NULL
                THEN 'Commitment Discount'
            WHEN src.injected_scenario = 'marketplace_subscription'
                THEN 'Other'
            WHEN src.cost_type = 'regular'
                THEN 'On-Demand'
            ELSE 'Other'
        END AS pricing_category,
        CASE
            WHEN lower(CAST(src.consumption_model.id AS VARCHAR)) LIKE '%flexiblecud%'
                THEN 'Flexible CUD'
            WHEN lower(CAST(src.consumption_model.id AS VARCHAR)) LIKE '%computecud%'
                THEN 'Compute CUD'
            WHEN lower(CAST(src.consumption_model.id AS VARCHAR)) LIKE '%resourcecud%'
                THEN 'Resource CUD'
            ELSE NULL
        END AS commitment_discount_category,
        NULLIF(CAST(src.modeled_commitment_profile_id AS VARCHAR), '') AS commitment_profile_id,
        CAST(src.usage.amount AS DOUBLE) AS usage_quantity,
        NULLIF(CAST(src.usage.unit AS VARCHAR), '') AS usage_unit,
        CAST(src.price.effective_price AS DOUBLE) AS list_unit_price,
        CAST(src.cost_at_list AS DOUBLE) AS list_cost,
        CAST(src.cost AS DOUBLE) AS contracted_cost,
        CAST(src.cost AS DOUBLE) AS billed_cost,
        CAST(src.cost AS DOUBLE) AS effective_cost,
        CAST(src.currency AS VARCHAR) AS billing_currency,
        NULLIF(CAST(src.application_name_value AS VARCHAR), '') AS application_name,
        NULLIF(CAST(src.department_name_value AS VARCHAR), '') AS department_name,
        NULLIF(CAST(src.environment_name_value AS VARCHAR), '') AS environment_name,
        NULLIF(CAST(src.cost_center_value AS VARCHAR), '') AS cost_center,
        NULLIF(CAST(src.owner_name_value AS VARCHAR), '') AS owner_name,
        CASE
            WHEN NULLIF(CAST(src.application_name_value AS VARCHAR), '') IS NULL
              OR NULLIF(CAST(src.department_name_value AS VARCHAR), '') IS NULL
              OR NULLIF(CAST(src.environment_name_value AS VARCHAR), '') IS NULL
              OR NULLIF(CAST(src.cost_center_value AS VARCHAR), '') IS NULL
            THEN 'Unallocated'
            ELSE 'Direct'
        END AS allocation_status,
        CAST(src.is_synthetic AS BOOLEAN) AS is_synthetic,
        CAST(src.is_late_arriving AS BOOLEAN) AS is_late_arriving,
        CAST(src.record_available_date AS DATE) AS record_available_date,
        CAST(src.data_quality_status AS VARCHAR) AS source_data_quality_status,
        src.duplicate_count > 1 AS is_duplicate,
        CAST(src.duplicate_rank AS BIGINT) AS duplicate_rank,
        src.duplicate_rank = 1 AS is_canonical_record,
        (
            src.duplicate_rank = 1
            AND src.data_quality_status <> 'INVALID_NEGATIVE_USAGE'
        ) AS is_valid_for_financial_reporting,
        NULLIF(CAST(src.injected_scenario AS VARCHAR), '') AS injected_scenario
    FROM source_ranked AS src
),
credit_rows AS (
    SELECT
        CAST(src.source_record_id AS VARCHAR)
            || '#credit#'
            || CAST(credit.id AS VARCHAR) AS record_id,
        CAST(src.source_record_id AS VARCHAR) AS parent_record_id,
        CAST(src.source_record_id AS VARCHAR) AS source_record_id,
        CAST(src.source_row_number AS BIGINT) AS source_row_number,
        'GCP_BILLING_EXPORT_STYLE' AS source_system,
        'GCP' AS provider_name,
        CAST(src.billing_account_id AS VARCHAR) AS billing_account_id,
        CAST(src.project.id AS VARCHAR) AS sub_account_id,
        CAST(src.project.name AS VARCHAR) AS sub_account_name,
        'GCP_PROJECT' AS sub_account_type,
        CAST(src.project.id AS VARCHAR) AS project_id,
        CAST(strptime(src.invoice.month || '01', '%Y%m%d') AS DATE) AS billing_period_start,
        CAST(
            CAST(strptime(src.invoice.month || '01', '%Y%m%d') AS DATE)
            + INTERVAL 1 MONTH
            AS DATE
        ) AS billing_period_end,
        CAST(src.usage_start_time AS TIMESTAMP) AS charge_period_start,
        CAST(src.usage_end_time AS TIMESTAMP) AS charge_period_end,
        CAST(src.service.description AS VARCHAR) AS service_name,
        CASE CAST(src.service.description AS VARCHAR)
            WHEN 'Compute Engine' THEN 'Compute'
            WHEN 'Cloud Run' THEN 'Serverless'
            WHEN 'Cloud SQL' THEN 'Database'
            WHEN 'Cloud Storage' THEN 'Storage'
            WHEN 'Cloud Logging' THEN 'Observability'
            WHEN 'Network Services' THEN 'Network'
            WHEN 'Vertex AI' THEN 'AI'
            WHEN 'Google Cloud Marketplace' THEN 'Marketplace'
            ELSE 'Other'
        END AS service_category,
        CAST(src.sku.id AS VARCHAR) AS sku_id,
        CAST(credit.full_name AS VARCHAR) AS sku_description,
        CAST(src.resource.global_name AS VARCHAR) AS resource_id,
        CAST(src.location.region AS VARCHAR) AS region_name,
        NULLIF(CAST(src.location.zone AS VARCHAR), '') AS availability_zone,
        'Credit' AS charge_category,
        CAST(credit.type AS VARCHAR) AS charge_class,
        CASE
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
                THEN 'Commitment Discount'
            ELSE 'Discount'
        END AS pricing_category,
        CASE
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
             AND lower(CAST(src.consumption_model.id AS VARCHAR)) LIKE '%flexiblecud%'
                THEN 'Flexible CUD'
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
             AND lower(CAST(src.consumption_model.id AS VARCHAR)) LIKE '%computecud%'
                THEN 'Compute CUD'
            WHEN credit.type = 'COMMITTED_USAGE_DISCOUNT'
             AND lower(CAST(src.consumption_model.id AS VARCHAR)) LIKE '%resourcecud%'
                THEN 'Resource CUD'
            ELSE NULL
        END AS commitment_discount_category,
        NULLIF(CAST(src.modeled_commitment_profile_id AS VARCHAR), '') AS commitment_profile_id,
        0.0 AS usage_quantity,
        CAST(NULL AS VARCHAR) AS usage_unit,
        0.0 AS list_unit_price,
        0.0 AS list_cost,
        CAST(credit.amount AS DOUBLE) AS contracted_cost,
        CAST(credit.amount AS DOUBLE) AS billed_cost,
        CAST(credit.amount AS DOUBLE) AS effective_cost,
        CAST(src.currency AS VARCHAR) AS billing_currency,
        NULLIF(CAST(src.application_name_value AS VARCHAR), '') AS application_name,
        NULLIF(CAST(src.department_name_value AS VARCHAR), '') AS department_name,
        NULLIF(CAST(src.environment_name_value AS VARCHAR), '') AS environment_name,
        NULLIF(CAST(src.cost_center_value AS VARCHAR), '') AS cost_center,
        NULLIF(CAST(src.owner_name_value AS VARCHAR), '') AS owner_name,
        CASE
            WHEN NULLIF(CAST(src.application_name_value AS VARCHAR), '') IS NULL
              OR NULLIF(CAST(src.department_name_value AS VARCHAR), '') IS NULL
              OR NULLIF(CAST(src.environment_name_value AS VARCHAR), '') IS NULL
              OR NULLIF(CAST(src.cost_center_value AS VARCHAR), '') IS NULL
            THEN 'Unallocated'
            ELSE 'Direct'
        END AS allocation_status,
        CAST(src.is_synthetic AS BOOLEAN) AS is_synthetic,
        CAST(src.is_late_arriving AS BOOLEAN) AS is_late_arriving,
        CAST(src.record_available_date AS DATE) AS record_available_date,
        CAST(src.data_quality_status AS VARCHAR) AS source_data_quality_status,
        src.duplicate_count > 1 AS is_duplicate,
        CAST(src.duplicate_rank AS BIGINT) AS duplicate_rank,
        src.duplicate_rank = 1 AS is_canonical_record,
        (
            src.duplicate_rank = 1
            AND src.data_quality_status <> 'INVALID_NEGATIVE_USAGE'
        ) AS is_valid_for_financial_reporting,
        NULLIF(CAST(src.injected_scenario AS VARCHAR), '') AS injected_scenario
    FROM source_ranked AS src
    CROSS JOIN UNNEST(src.credits) AS credit_table(credit)
)
SELECT * FROM parent_rows
UNION ALL
SELECT * FROM credit_rows;

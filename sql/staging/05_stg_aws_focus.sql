/*
Purpose:
    Transform provider-specific AWS raw billing records into the common
    FOCUS-aligned staging schema.

Grain:
    One staging row per physical AWS raw billing row.

Source:
    __PROJECT_ID__.retail_finops_raw.raw_aws_billing

Key controls:
    - Preserve payer account and usage account as different hierarchy levels.
    - Preserve duplicate source line-item IDs and mark one canonical row.
    - Keep monetary fields as BigQuery NUMERIC.
    - Classify charges from AWS line-item type, not from amount sign.
    - Do not combine AWS with GCP until after provider-specific conformance.

Owner:
    FinOps Analytics.

Refresh:
    Rebuilt after each approved AWS raw ingestion.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_staging.stg_aws_focus`

PARTITION BY DATE(charge_period_start)

CLUSTER BY
    billing_account_id,
    service_name,
    application_name,
    charge_category

AS

WITH source_rows AS (
    SELECT
        CAST(raw.raw_row_id AS STRING) AS raw_row_id,
        CAST(raw.pipeline_run_id AS STRING) AS pipeline_run_id,
        CAST(raw.source_file AS STRING) AS source_file,
        CAST(raw.ingestion_timestamp AS TIMESTAMP) AS ingestion_timestamp,

        CAST(raw.line_item_line_item_id AS STRING) AS source_record_id,
        CAST(raw.bill_payer_account_id AS STRING) AS bill_payer_account_id,
        CAST(raw.line_item_usage_account_id AS STRING)
            AS line_item_usage_account_id,

        SAFE_CAST(raw.bill_billing_period_start_date AS DATE)
            AS billing_period_start,
        SAFE_CAST(raw.bill_billing_period_end_date AS DATE)
            AS billing_period_end,
        SAFE_CAST(raw.line_item_usage_start_date AS TIMESTAMP)
            AS charge_period_start,
        SAFE_CAST(raw.line_item_usage_end_date AS TIMESTAMP)
            AS charge_period_end,

        CAST(raw.line_item_line_item_type AS STRING)
            AS line_item_line_item_type,
        CAST(raw.line_item_product_code AS STRING)
            AS line_item_product_code,
        CAST(raw.product_product_name AS STRING)
            AS product_product_name,
        CAST(raw.product_region AS STRING) AS product_region,
        CAST(raw.line_item_resource_id AS STRING)
            AS line_item_resource_id,
        CAST(raw.line_item_usage_type AS STRING)
            AS line_item_usage_type,
        CAST(raw.line_item_line_item_description AS STRING)
            AS line_item_line_item_description,

        CAST(raw.pricing_unit AS STRING) AS pricing_unit,
        SAFE_CAST(raw.line_item_usage_amount AS NUMERIC)
            AS line_item_usage_amount,
        SAFE_CAST(raw.pricing_public_on_demand_cost AS NUMERIC)
            AS pricing_public_on_demand_cost,
        SAFE_CAST(raw.line_item_unblended_cost AS NUMERIC)
            AS line_item_unblended_cost,
        SAFE_CAST(raw.reservation_effective_cost AS NUMERIC)
            AS reservation_effective_cost,
        SAFE_CAST(raw.reservation_unused_recurring_fee AS NUMERIC)
            AS reservation_unused_recurring_fee,
        SAFE_CAST(
            raw.savings_plan_savings_plan_effective_cost AS NUMERIC
        ) AS savings_plan_effective_cost,
        SAFE_CAST(raw.savings_plan_unused_commitment AS NUMERIC)
            AS savings_plan_unused_commitment,

        CAST(raw.line_item_currency_code AS STRING)
            AS line_item_currency_code,
        CAST(raw.commitment_profile_id AS STRING)
            AS commitment_profile_id,

        CAST(raw.resource_tags_user_application AS STRING)
            AS application_name_value,
        CAST(raw.resource_tags_user_department AS STRING)
            AS department_name_value,
        CAST(raw.resource_tags_user_environment AS STRING)
            AS environment_name_value,
        CAST(raw.resource_tags_user_cost_center AS STRING)
            AS cost_center_value,
        CAST(raw.resource_tags_user_owner AS STRING)
            AS owner_name_value,

        CAST(raw.is_synthetic AS BOOL) AS is_synthetic,
        CAST(raw.is_late_arriving AS BOOL) AS is_late_arriving,
        CAST(raw.data_quality_status AS STRING)
            AS data_quality_status

    FROM
        `__PROJECT_ID__.retail_finops_raw.raw_aws_billing` AS raw
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
)

SELECT
    raw_row_id AS record_id,
    CAST(NULL AS STRING) AS parent_record_id,
    source_record_id,
    pipeline_run_id,
    'AWS_CUR' AS source_system,
    source_file,
    ingestion_timestamp,
    '1.2' AS focus_spec_version,
    is_synthetic,
    is_late_arriving,

    billing_period_start,
    billing_period_end,
    charge_period_start,
    charge_period_end,
    CONCAT(
        'AWS-',
        FORMAT_DATE('%Y%m', billing_period_start)
    ) AS invoice_id,
    line_item_currency_code AS billing_currency,

    'AWS' AS provider_name,
    bill_payer_account_id AS billing_account_id,
    CAST(NULL AS STRING) AS billing_account_name,
    line_item_usage_account_id AS sub_account_id,
    CAST(NULL AS STRING) AS sub_account_name,
    'AWS_USAGE_ACCOUNT' AS sub_account_type,
    CAST(NULL AS STRING) AS project_id,

    CASE line_item_product_code
        WHEN 'AmazonEC2' THEN 'Compute'
        WHEN 'AWSLambda' THEN 'Serverless'
        WHEN 'AmazonRDS' THEN 'Database'
        WHEN 'AmazonS3' THEN 'Storage'
        WHEN 'AmazonCloudWatch' THEN 'Observability'
        WHEN 'AmazonVPC' THEN 'Network'
        WHEN 'AmazonBedrock' THEN 'AI'
        WHEN 'AWSMarketplace' THEN 'Marketplace'
        ELSE 'Other'
    END AS service_category,

    product_product_name AS service_name,
    line_item_usage_type AS sku_id,
    line_item_line_item_description AS sku_name,
    NULLIF(line_item_resource_id, '') AS resource_id,
    NULLIF(line_item_line_item_description, '') AS resource_name,
    NULLIF(product_region, '') AS region_name,
    CAST(NULL AS STRING) AS availability_zone,

    CASE
        WHEN line_item_line_item_type IN (
            'Usage',
            'DiscountedUsage',
            'SavingsPlanCoveredUsage'
        )
            THEN 'Usage'
        WHEN line_item_line_item_type IN (
            'Fee',
            'RIFee',
            'SavingsPlanRecurringFee'
        )
            THEN 'Purchase'
        WHEN line_item_line_item_type IN (
            'Credit',
            'SavingsPlanNegation'
        )
            THEN 'Credit'
        WHEN line_item_line_item_type = 'Refund'
            THEN 'Adjustment'
        ELSE 'Adjustment'
    END AS charge_category,

    line_item_line_item_type AS charge_class,

    CASE
        WHEN line_item_line_item_type IN (
            'Fee',
            'RIFee',
            'SavingsPlanRecurringFee'
        )
            THEN 'Recurring'
        WHEN line_item_line_item_type IN (
            'Credit',
            'Refund',
            'SavingsPlanNegation'
        )
            THEN 'One-Time'
        ELSE 'Usage-Based'
    END AS charge_frequency,

    CASE
        WHEN line_item_line_item_type IN (
            'DiscountedUsage',
            'SavingsPlanCoveredUsage',
            'RIFee',
            'SavingsPlanRecurringFee'
        )
            THEN 'Commitment Discount'
        WHEN line_item_line_item_type = 'Usage'
            THEN 'On-Demand'
        ELSE 'Other'
    END AS pricing_category,

    NULLIF(commitment_profile_id, '')
        AS commitment_discount_id,

    CASE
        WHEN line_item_line_item_type IN (
            'DiscountedUsage',
            'RIFee'
        )
            THEN 'Reserved Instance'
        WHEN line_item_line_item_type IN (
            'SavingsPlanCoveredUsage',
            'SavingsPlanRecurringFee',
            'SavingsPlanNegation'
        )
            THEN 'Savings Plan'
        ELSE CAST(NULL AS STRING)
    END AS commitment_discount_type,

    CASE
        WHEN LOWER(commitment_profile_id) LIKE '%over%'
            THEN 'Underutilized'
        WHEN LOWER(commitment_profile_id) LIKE '%under%'
            THEN 'Undercovered'
        WHEN LOWER(commitment_profile_id) LIKE '%balanced%'
            THEN 'Balanced'
        WHEN NULLIF(commitment_profile_id, '') IS NOT NULL
            THEN 'Modeled'
        ELSE CAST(NULL AS STRING)
    END AS commitment_discount_status,

    COALESCE(
        pricing_public_on_demand_cost,
        NUMERIC '0'
    ) AS list_cost,

    CASE
        WHEN line_item_line_item_type = 'DiscountedUsage'
            THEN COALESCE(
                reservation_effective_cost,
                NUMERIC '0'
            )
        WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
            THEN COALESCE(
                savings_plan_effective_cost,
                NUMERIC '0'
            )
        ELSE COALESCE(
            line_item_unblended_cost,
            NUMERIC '0'
        )
    END AS contracted_cost,

    COALESCE(
        line_item_unblended_cost,
        NUMERIC '0'
    ) AS billed_cost,

    CASE
        WHEN line_item_line_item_type = 'DiscountedUsage'
            THEN COALESCE(
                reservation_effective_cost,
                NUMERIC '0'
            )
        WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
            THEN COALESCE(
                savings_plan_effective_cost,
                NUMERIC '0'
            )
        WHEN line_item_line_item_type = 'RIFee'
            THEN COALESCE(
                reservation_unused_recurring_fee,
                NUMERIC '0'
            )
        WHEN line_item_line_item_type = 'SavingsPlanRecurringFee'
            THEN COALESCE(
                savings_plan_unused_commitment,
                NUMERIC '0'
            )
        ELSE COALESCE(
            line_item_unblended_cost,
            NUMERIC '0'
        )
    END AS effective_cost,

    line_item_usage_amount AS consumed_quantity,
    NULLIF(pricing_unit, '') AS consumed_unit,

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

    line_item_line_item_type AS x_aws_line_item_type,
    CAST(NULL AS STRING) AS x_gcp_cost_type,
    CAST(NULL AS STRING) AS x_credit_type,
    data_quality_status AS x_source_record_status

FROM
    ranked_source_rows;

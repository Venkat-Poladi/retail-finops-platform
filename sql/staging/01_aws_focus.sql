-- Purpose: Normalize AWS CUR/Data Export-style rows into the project FOCUS-aligned schema.
-- Grain: One row per AWS source billing line item. Deliberate duplicate IDs remain flagged.

CREATE OR REPLACE TABLE stg_aws_focus AS
WITH source_ranked AS (
    SELECT
        raw.*,
        COUNT(*) OVER (
            PARTITION BY line_item_line_item_id
        ) AS duplicate_count,
        ROW_NUMBER() OVER (
            PARTITION BY line_item_line_item_id
            ORDER BY source_row_number
        ) AS duplicate_rank
    FROM raw_aws_billing AS raw
),
account_names AS (
    SELECT
        CAST(usage_account_id AS VARCHAR) AS usage_account_id,
        usage_account_name
    FROM aws_accounts_config
)
SELECT
    CAST(src.line_item_line_item_id AS VARCHAR) AS record_id,
    CAST(NULL AS VARCHAR) AS parent_record_id,
    CAST(src.line_item_line_item_id AS VARCHAR) AS source_record_id,
    CAST(src.source_row_number AS BIGINT) AS source_row_number,
    'AWS_CUR_STYLE' AS source_system,
    'AWS' AS provider_name,
    CAST(src.bill_payer_account_id AS VARCHAR) AS billing_account_id,
    CAST(src.line_item_usage_account_id AS VARCHAR) AS sub_account_id,
    acct.usage_account_name AS sub_account_name,
    'AWS_USAGE_ACCOUNT' AS sub_account_type,
    CAST(NULL AS VARCHAR) AS project_id,
    CAST(src.bill_billing_period_start_date AS DATE) AS billing_period_start,
    CAST(src.bill_billing_period_end_date AS DATE) AS billing_period_end,
    CAST(src.line_item_usage_start_date AS TIMESTAMP) AS charge_period_start,
    CAST(src.line_item_usage_end_date AS TIMESTAMP) AS charge_period_end,
    CAST(src.product_product_name AS VARCHAR) AS service_name,
    CASE CAST(src.line_item_product_code AS VARCHAR)
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
    CAST(src.line_item_usage_type AS VARCHAR) AS sku_id,
    CAST(src.line_item_line_item_description AS VARCHAR) AS sku_description,
    NULLIF(CAST(src.line_item_resource_id AS VARCHAR), '') AS resource_id,
    CAST(src.product_region AS VARCHAR) AS region_name,
    CAST(NULL AS VARCHAR) AS availability_zone,
    CASE CAST(src.line_item_line_item_type AS VARCHAR)
        WHEN 'Fee' THEN 'Purchase'
        WHEN 'RIFee' THEN 'Purchase'
        WHEN 'SavingsPlanRecurringFee' THEN 'Purchase'
        WHEN 'Credit' THEN 'Credit'
        WHEN 'Refund' THEN 'Credit'
        ELSE 'Usage'
    END AS charge_category,
    CAST(src.line_item_line_item_type AS VARCHAR) AS charge_class,
    CASE
        WHEN src.line_item_line_item_type IN (
            'DiscountedUsage',
            'SavingsPlanCoveredUsage',
            'RIFee',
            'SavingsPlanRecurringFee'
        ) THEN 'Commitment Discount'
        WHEN src.line_item_line_item_type = 'Usage' THEN 'On-Demand'
        ELSE 'Other'
    END AS pricing_category,
    CASE
        WHEN src.line_item_line_item_type IN ('DiscountedUsage', 'RIFee')
            THEN 'Reserved Instance'
        WHEN src.line_item_line_item_type IN (
            'SavingsPlanCoveredUsage',
            'SavingsPlanRecurringFee'
        ) THEN 'Savings Plan'
        ELSE NULL
    END AS commitment_discount_category,
    NULLIF(CAST(src.commitment_profile_id AS VARCHAR), '') AS commitment_profile_id,
    CAST(src.line_item_usage_amount AS DOUBLE) AS usage_quantity,
    NULLIF(CAST(src.pricing_unit AS VARCHAR), '') AS usage_unit,
    CAST(src.pricing_public_on_demand_rate AS DOUBLE) AS list_unit_price,
    CAST(src.pricing_public_on_demand_cost AS DOUBLE) AS list_cost,
    CASE
        WHEN src.line_item_line_item_type = 'DiscountedUsage'
            THEN CAST(src.reservation_effective_cost AS DOUBLE)
        WHEN src.line_item_line_item_type = 'SavingsPlanCoveredUsage'
            THEN CAST(src.savings_plan_savings_plan_effective_cost AS DOUBLE)
        ELSE CAST(src.line_item_unblended_cost AS DOUBLE)
    END AS contracted_cost,
    CAST(src.line_item_unblended_cost AS DOUBLE) AS billed_cost,
    CASE
        WHEN src.line_item_line_item_type = 'DiscountedUsage'
            THEN CAST(src.reservation_effective_cost AS DOUBLE)
        WHEN src.line_item_line_item_type = 'SavingsPlanCoveredUsage'
            THEN CAST(src.savings_plan_savings_plan_effective_cost AS DOUBLE)
        WHEN src.line_item_line_item_type = 'RIFee'
            THEN CAST(src.reservation_unused_recurring_fee AS DOUBLE)
        WHEN src.line_item_line_item_type = 'SavingsPlanRecurringFee'
            THEN CAST(src.savings_plan_unused_commitment AS DOUBLE)
        ELSE CAST(src.line_item_unblended_cost AS DOUBLE)
    END AS effective_cost,
    CAST(src.line_item_currency_code AS VARCHAR) AS billing_currency,
    NULLIF(CAST(src.resource_tags_user_application AS VARCHAR), '') AS application_name,
    NULLIF(CAST(src.resource_tags_user_department AS VARCHAR), '') AS department_name,
    NULLIF(CAST(src.resource_tags_user_environment AS VARCHAR), '') AS environment_name,
    NULLIF(CAST(src.resource_tags_user_cost_center AS VARCHAR), '') AS cost_center,
    NULLIF(CAST(src.resource_tags_user_owner AS VARCHAR), '') AS owner_name,
    CASE
        WHEN NULLIF(CAST(src.resource_tags_user_application AS VARCHAR), '') IS NULL
          OR NULLIF(CAST(src.resource_tags_user_department AS VARCHAR), '') IS NULL
          OR NULLIF(CAST(src.resource_tags_user_environment AS VARCHAR), '') IS NULL
          OR NULLIF(CAST(src.resource_tags_user_cost_center AS VARCHAR), '') IS NULL
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
LEFT JOIN account_names AS acct
    ON CAST(src.line_item_usage_account_id AS VARCHAR) = acct.usage_account_id;

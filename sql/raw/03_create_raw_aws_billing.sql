/*
Purpose:
    Promote the temporary AWS load table into the controlled raw layer.

Grain:
    One row per original AWS billing line item.

Source:
    retail_finops_raw._load_aws_billing

Key controls:
    - Preserve all AWS provider-native billing columns.
    - Convert account identifiers to STRING.
    - Add ingestion and pipeline lineage metadata.
    - Preserve duplicate source line-item IDs.
    - Assign a stable raw-row identifier to each physical source row.

Owner:
    FinOps Analytics.
*/

CREATE OR REPLACE TABLE
    `finops-learning-lab.retail_finops_raw.raw_aws_billing`

PARTITION BY
    DATE(line_item_usage_start_date)

CLUSTER BY
    bill_payer_account_id,
    line_item_usage_account_id,
    line_item_line_item_type,
    line_item_product_code

AS

WITH numbered_source_rows AS (
    SELECT
        source.*,

        ROW_NUMBER() OVER (
            PARTITION BY
                CAST(line_item_line_item_id AS STRING)
            ORDER BY
                line_item_usage_start_date,
                line_item_usage_end_date,
                line_item_product_code,
                line_item_resource_id,
                line_item_unblended_cost
        ) AS source_occurrence_number

    FROM
        `finops-learning-lab.retail_finops_raw._load_aws_billing`
            AS source
)

SELECT
    CONCAT(
        'AWS-RAW-',
        COALESCE(
            CAST(line_item_line_item_id AS STRING),
            'MISSING-ID'
        ),
        '-',
        LPAD(
            CAST(source_occurrence_number AS STRING),
            3,
            '0'
        )
    ) AS raw_row_id,

    'AWS-INITIAL-LOAD-001' AS pipeline_run_id,
    'aws_billing.csv' AS source_file,
    CURRENT_TIMESTAMP() AS ingestion_timestamp,

    CAST(bill_payer_account_id AS STRING)
        AS bill_payer_account_id,

    bill_billing_period_start_date,
    bill_billing_period_end_date,

    CAST(line_item_usage_account_id AS STRING)
        AS line_item_usage_account_id,

    line_item_line_item_id,
    line_item_usage_start_date,
    line_item_usage_end_date,
    line_item_line_item_type,
    line_item_product_code,
    product_product_name,
    product_region,
    line_item_resource_id,
    line_item_usage_type,
    line_item_operation,
    line_item_line_item_description,

    pricing_unit,
    line_item_usage_amount,
    pricing_public_on_demand_rate,
    pricing_public_on_demand_cost,
    line_item_unblended_rate,
    line_item_unblended_cost,

    reservation_effective_cost,
    reservation_unused_recurring_fee,
    savings_plan_savings_plan_effective_cost,
    savings_plan_unused_commitment,

    line_item_currency_code,
    pricing_term,
    pricing_purchase_option,
    commitment_profile_id,

    resource_tags_user_application,
    resource_tags_user_department,
    resource_tags_user_environment,
    resource_tags_user_cost_center,
    resource_tags_user_owner,

    is_synthetic,
    is_late_arriving,
    record_available_date,
    data_quality_status,
    injected_scenario

FROM
    numbered_source_rows;

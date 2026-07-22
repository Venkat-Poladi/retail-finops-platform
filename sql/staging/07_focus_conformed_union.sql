/*
Purpose: Create the post-conformance AWS and GCP billing union.
Grain: One row per normalized provider billing charge.
Sources:
  - retail_finops_staging.stg_aws_focus
  - retail_finops_staging.stg_gcp_focus
Key control: Both SELECT statements use the same explicit columns
             in the same order.
*/

CREATE OR REPLACE VIEW
    `__PROJECT_ID__.retail_finops_staging.vw_focus_conformed_union`
AS

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
    `__PROJECT_ID__.retail_finops_staging.stg_aws_focus`

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
    `__PROJECT_ID__.retail_finops_staging.stg_gcp_focus`;

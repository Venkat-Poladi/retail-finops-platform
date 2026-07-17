/*
Purpose:
    Build the central approved cloud-cost fact table from the conformed
    AWS and GCP staging union.

Grain:
    One canonical, financially valid normalized billing charge per record_id.

Controls:
    - No dimension joins are performed here.
    - Duplicate and invalid evidence remains in staging.
    - allocated_cost remains NULL until the allocation milestone.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`

PARTITION BY DATE(charge_period_start)

CLUSTER BY
    provider_name,
    billing_account_id,
    application_name,
    service_category

AS

SELECT
    -- 1. Identification and lineage
    record_id,
    parent_record_id,
    source_record_id,
    pipeline_run_id,
    source_system,
    source_file,
    ingestion_timestamp,
    is_synthetic,
    is_late_arriving,
    'APPROVED' AS data_status,

    -- 2. Time and invoice
    billing_period_start,
    billing_period_end,
    charge_period_start,
    charge_period_end,
    invoice_id,
    billing_currency,

    -- 3. Provider hierarchy
    provider_name,
    billing_account_id,
    billing_account_name,
    sub_account_id,
    sub_account_name,
    sub_account_type,
    project_id,

    -- 4. Business hierarchy
    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,

    -- 5. Service and resource
    service_category,
    service_name,
    sku_id,
    sku_name,
    resource_id,
    resource_name,
    region_name,
    availability_zone,

    -- 6. Charge and pricing
    charge_category,
    charge_class,
    charge_frequency,
    pricing_category,
    commitment_discount_id,
    commitment_discount_type,
    commitment_discount_status,
    consumed_quantity,
    consumed_unit,

    -- 7. Financial measures
    list_cost,
    contracted_cost,
    billed_cost,
    effective_cost,
    CAST(NULL AS NUMERIC) AS allocated_cost,

    -- 8. Allocation and controls
    allocation_status,
    is_duplicate,
    duplicate_rank,
    is_canonical_record,
    is_valid_for_financial_reporting,
    data_quality_reason

FROM
    `__PROJECT_ID__.retail_finops_staging.vw_focus_conformed_union`

WHERE
    is_canonical_record = TRUE
    AND is_valid_for_financial_reporting = TRUE;

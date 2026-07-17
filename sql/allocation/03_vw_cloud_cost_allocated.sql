/*
Purpose:
    Expose the approved cost fact together with allocation targets and
    allocated financial amounts.

Grain:
    One row per source record and allocation target.

Source:
    retail_finops_core.fct_cloud_cost
    retail_finops_core.fct_cost_allocation

Key controls:
    - Source fact attributes remain traceable.
    - Shared records can create multiple allocation rows.
    - allocated_cost comes from the allocation fact, not the base fact.

Owner:
    FinOps

Refresh:
    View; reflects current source tables.
*/

CREATE OR REPLACE VIEW
    `__PROJECT_ID__.retail_finops_core.vw_cloud_cost_allocated`

AS

SELECT
    allocation.allocation_id,

    fact.record_id,
    fact.parent_record_id,
    fact.source_record_id,
    fact.pipeline_run_id,
    fact.source_system,
    fact.source_file,
    fact.ingestion_timestamp,

    fact.is_synthetic,
    fact.is_late_arriving,
    fact.data_status,

    fact.billing_period_start,
    fact.billing_period_end,
    fact.charge_period_start,
    fact.charge_period_end,
    fact.invoice_id,

    allocation.billing_month,

    fact.provider_name,
    fact.billing_account_id,
    fact.billing_account_name,
    fact.sub_account_id,
    fact.sub_account_name,
    fact.sub_account_type,
    fact.project_id,

    allocation.source_application_name,
    allocation.source_department_name,
    allocation.source_environment_name,
    allocation.source_cost_center,
    allocation.source_owner_name,

    allocation.target_application_name,
    allocation.target_department_name,
    allocation.target_environment_name,
    allocation.target_cost_center,
    allocation.target_owner_name,

    fact.service_category,
    fact.service_name,
    fact.sku_id,
    fact.sku_name,
    fact.resource_id,
    fact.resource_name,
    fact.region_name,
    fact.availability_zone,

    fact.charge_category,
    fact.charge_class,
    fact.charge_frequency,
    fact.pricing_category,

    fact.commitment_discount_id,
    fact.commitment_discount_type,
    fact.commitment_discount_status,

    fact.consumed_quantity,
    fact.consumed_unit,

    fact.list_cost,
    fact.contracted_cost,
    fact.billed_cost,
    fact.effective_cost,

    allocation.source_billed_cost,
    allocation.allocated_cost,

    fact.billing_currency,

    allocation.allocation_method,
    allocation.allocation_driver,
    allocation.driver_scope,
    allocation.driver_value,
    allocation.driver_total,
    allocation.allocation_weight,

    allocation.is_allocated,
    allocation.allocation_status,
    allocation.allocation_rule_id,

    allocation.data_refresh_timestamp

FROM
    `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`
        AS fact

INNER JOIN
    `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
        AS allocation

    ON fact.record_id = allocation.record_id;
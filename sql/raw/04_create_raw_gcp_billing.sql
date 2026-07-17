/*
Purpose:
    Promote the temporary GCP load table into the controlled raw layer.

Grain:
    One row per original GCP billing source record.

Source:
    retail_finops_raw._load_gcp_billing

Key controls:
    Preserve all provider-native nested and repeated fields.
    Add ingestion and lineage metadata.
*/

CREATE OR REPLACE TABLE
    `finops-learning-lab.retail_finops_raw.raw_gcp_billing`

PARTITION BY DATE(usage_start_time)

CLUSTER BY
    billing_account_id,
    cost_type

AS

SELECT
    GENERATE_UUID() AS raw_row_id,
    'GCP-INITIAL-LOAD-001' AS pipeline_run_id,
    'gcp_billing.jsonl' AS source_file,
    CURRENT_TIMESTAMP() AS ingestion_timestamp,
    source.*

FROM
    `finops-learning-lab.retail_finops_raw._load_gcp_billing` AS source;

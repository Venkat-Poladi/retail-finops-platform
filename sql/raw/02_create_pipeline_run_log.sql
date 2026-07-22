/*
Purpose: Record every provider billing-file ingestion attempt.
Grain: One row per provider source-file load attempt.
Source: Raw ingestion process.
Key controls: File duplication, row-count reconciliation, cost reconciliation,
load status, and error capture.
Owner: FinOps Analytics.
Refresh: One record per ingestion attempt.
*/

CREATE TABLE IF NOT EXISTS
    `retail_finops_control.pipeline_run_log`
(
    pipeline_run_id STRING NOT NULL,
    provider_name STRING NOT NULL,
    source_file STRING NOT NULL,
    source_file_hash STRING,
    source_file_uri STRING,

    load_started_at TIMESTAMP NOT NULL,
    load_completed_at TIMESTAMP,

    source_row_count INT64,
    loaded_row_count INT64,
    row_count_variance INT64,

    source_net_cost NUMERIC,
    loaded_net_cost NUMERIC,
    cost_variance NUMERIC,

    load_status STRING NOT NULL,
    is_duplicate_file BOOL NOT NULL,
    error_message STRING
)
PARTITION BY DATE(load_started_at)
CLUSTER BY provider_name, load_status;

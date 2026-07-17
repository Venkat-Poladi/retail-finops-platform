/*
Purpose: Create the datasets required for the BigQuery raw layer.
Grain: Dataset-level setup.
Source: None.
Key controls: Provider-native billing remains separate.
Owner: FinOps Analytics.
Refresh: One-time infrastructure setup.
*/

CREATE SCHEMA IF NOT EXISTS `retail_finops_raw`
OPTIONS (
    location = 'US',
    description = 'Provider-native AWS and GCP billing data.'
);

CREATE SCHEMA IF NOT EXISTS `retail_finops_control`
OPTIONS (
    location = 'US',
    description = 'Pipeline logging, reconciliation, and data-quality controls.'
);

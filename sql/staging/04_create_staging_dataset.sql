/*
Purpose:
    Create the BigQuery dataset used for provider-specific
    FOCUS-aligned transformations.

Grain:
    Dataset setup.

Source:
    retail_finops_raw

Key controls:
    AWS and GCP remain separate until both providers have been conformed.

Owner:
    FinOps Analytics

Refresh:
    Infrastructure setup
*/

CREATE SCHEMA IF NOT EXISTS `${PROJECT_ID}.retail_finops_staging`
OPTIONS (
    location = 'US',
    description = 'Provider-specific FOCUS-aligned cloud billing staging tables.'
);
/*
Purpose:
    Create the governed BigQuery dataset for approved FinOps core tables.

Milestone:
    10 — Core Cloud Cost Fact Table.
*/

CREATE SCHEMA IF NOT EXISTS
    `__PROJECT_ID__.retail_finops_core`
OPTIONS (
    location = 'US',
    description = 'Approved canonical cloud-cost facts for Retail Co FinOps.'
);

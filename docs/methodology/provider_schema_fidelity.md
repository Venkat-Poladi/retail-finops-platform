# Provider Schema Fidelity

**Schema reference date:** July 15, 2026

## Positioning

The project generates **provider-native, structurally realistic subsets** of AWS and Google Cloud billing exports. The source data is intentionally synthetic, but the schema, hierarchy, nested structures, charge behavior, billing metadata, commitment behavior, credits, refunds, late arrivals, duplicates, invalid records, and financial controls are designed to resemble enterprise billing data.

The project does **not** claim to reproduce every possible AWS or Google Cloud export column. Provider schemas evolve, optional fields appear only when applicable, and AWS product, discount, cost-category, and service-specific columns can vary with customer usage.

## AWS source model

The AWS output is a flat, wide CUR/Data Exports-style subset. It includes payer and usage-account hierarchy, billing periods, line-item identifiers and types, usage periods, service and resource fields, pricing terms, purchase options, list/contracted/billed/effective costs, RI and Savings Plans fields, and activated business tags.

Milestone 8A adds these native-style bill fields:

- `bill_bill_type`
- `bill_billing_entity`
- `bill_invoice_id`
- `bill_invoicing_entity`

AWS documents `bill/PayerAccountId`, but not `bill/PayerAccountName` as a standard static CUR bill column. Therefore, the friendly payer name is stored honestly as the project extension `x_payer_account_name`.

The generator does not manufacture generic `cost_category` or `discount` columns. AWS cost-category and discount columns can be dynamic and are represented in this project through business tags, pricing categories, negotiated/effective-cost fields, and commitment metadata.

## Google Cloud source model

The GCP output remains newline-delimited JSON with nested and repeated records. Milestone 8A corrects:

- `system_labels` to repeated `{key, value}` records.
- `tags` to repeated `{key, value, inherited, namespace}` records.

It also adds:

- `transaction_type`
- `seller_name`
- `subscription.instance_id`
- `cost_at_effective_price_default`
- `cost_at_list_consumption_model`

The generator preserves nested `project`, `service`, `sku`, `usage`, `price`, `invoice`, `labels`, `credits`, `resource`, `adjustment_info`, and `consumption_model` structures.

## Financial integrity

Schema hardening must not alter:

- Source row counts
- AWS billed-cost totals
- GCP cost or nested credit totals
- Duplicate and invalid record counts
- Missing metadata rates
- Late-arriving records
- Injected business anomalies
- Commitment coverage and utilization behavior

`data/schema_hardening/provider_schema_hardening_summary.json` records before/after row counts, financial totals, variances, and file hashes.

## Official references

- AWS Data Exports — CUR data dictionary and billing details: `https://docs.aws.amazon.com/cur/latest/userguide/data-dictionary.html`
- Google Cloud Billing — Detailed usage cost export structure: `https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/detailed-usage`
- FOCUS Specification: `https://focus.finops.org/focus-specification/`

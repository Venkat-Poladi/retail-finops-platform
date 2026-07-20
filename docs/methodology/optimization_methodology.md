# Cost Optimization and Savings Lifecycle Methodology

## Purpose

Create traceable, modeled optimization recommendations from the approved
Retail Co. cloud-cost fact table.

The output demonstrates how a FinOps team identifies, prioritizes, approves,
implements and validates savings opportunities.

Retail Co. is fictional. All savings produced by this milestone are modeled.

## Baseline period

The baseline is the average monthly positive Usage effective cost for the
latest three complete months in `fct_cloud_cost`.

Credits, refunds, taxes, adjustments and purchases do not inflate the
resource usage baseline.

Commitment purchase and unused-commitment rows are analyzed separately.

## Recommendation categories

### Compute rightsizing review

Modeled reduction: 15%.

The billing pattern identifies a review candidate. Billing records alone do
not prove that a resource is oversized.

Before implementation, validate:

- CPU utilization
- Memory utilization
- Network utilization
- Peak demand
- Availability requirements
- Provider rightsizing recommendations

### Non-production scheduling

Modeled reduction: 35%.

Applicable to eligible non-production compute and database resources.

Validate:

- Required working hours
- Batch schedules
- Development and testing dependencies
- Start-up time
- Support requirements

### Logging and monitoring

Modeled reduction: 20%.

Review:

- Log ingestion
- Debug logging
- Retention
- Metric cardinality
- Duplicate telemetry
- Sampling

### Storage lifecycle

Modeled reduction: 18%.

Review:

- Storage classes
- Lifecycle policies
- Old snapshots
- Retention requirements
- Replication
- Unused data

### Network architecture

Modeled reduction: 15%.

Review:

- NAT processing
- Internet egress
- Cross-zone traffic
- Cross-region traffic
- Routing
- Private service endpoints

### Commitment coverage

Modeled reduction: 18% of eligible on-demand cost after usage optimization.

AWS analysis includes Savings Plans and Reserved Instances.

GCP analysis includes Committed Use Discounts.

Commitment purchases must occur only after usage optimization and stability
analysis.

### Commitment utilization

Modeled recovery: 50% of identified unused commitment cost.

Possible actions include:

- Rebalance or exchange eligible commitments
- Allow unnecessary commitments to expire
- Improve workload coverage
- Reduce future purchases
- Review commitment scope

Provider contract rules must be validated before taking action.

## Overlap control

Recommendations affecting the same resource share an `overlap_group_id`.

For dependent recommendations:

1. Apply usage optimization.
2. Recalculate the remaining baseline.
3. Apply rate optimization to the remaining cost.

Required fields:

- baseline_cost
- dependency_recommendation_id
- overlap_group_id
- gross_savings
- overlap_adjustment
- net_monthly_savings
- calculation_order

Only net monthly savings enter portfolio totals.

## Savings lifecycle

Controlled stages:

- Identified
- Approved
- Implemented
- Realized
- Rejected
- On Hold

The milestone uses a deterministic modeled workflow to demonstrate lifecycle
governance.

This does not mean Retail Co. actually approved or implemented changes.

Every row contains:

- `savings_value_type = MODELED`
- `lifecycle_basis = MODELED_WORKFLOW_DEMONSTRATION`

Modeled realized savings use an 85% realization assumption and must never be
described as actual company savings.

## Funnel calculation

Identified:

All active net opportunities.

Approved:

Approved + Implemented + Realized net opportunities.

Implemented:

Implemented + Realized net opportunities.

Realized:

Only modeled realized savings.

Therefore:

Identified >= Approved >= Implemented >= Realized

## Limitations

The billing dataset does not contain:

- CPU utilization
- Memory utilization
- Application performance
- Service-level objectives
- Engineering dependency information
- Actual implementation evidence
- Actual post-implementation savings

Recommendations are candidates for investigation, not automatic remediation
instructions.

## Permitted interview statement

"The platform identified modeled monthly savings opportunities and
demonstrated how they can be tracked from identification through approval,
implementation and realization while preventing overlapping recommendations
from double-counting savings."

## Prohibited interview statement

"I saved Retail Co. the modeled amount."

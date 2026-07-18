# Cost Anomaly Detection Methodology

## Purpose

Detect material daily cloud-cost increases from the approved Retail Co.
cloud-cost fact table and connect every finding to an accountable owner,
recommended action and contributing source records.

## Detection grain

One daily cost series per:

- Provider
- Billing account
- Sub-account or project
- Application
- Department
- Environment
- Cost center
- Owner
- Service
- Resource
- Region
- Currency

## Cost population

The anomaly detector uses positive Usage cost.

Credits, refunds, taxes, purchases and adjustments remain in the full
daily financial series, but they do not create anomaly signals.

This prevents legitimate negative credits or one-time invoice adjustments
from creating misleading cost-increase alerts.

## Baseline

Primary baseline:

- Median of the previous 14 daily observations
- Current day excluded
- Minimum seven observations

Seasonality guardrail:

- Median for the same weekday over the previous 56 days
- Used when at least four same-weekday observations exist
- Selected baseline is the larger of the trailing median and
  same-weekday median

This guardrail reduces the chance that normal weekday/weekend behavior is
classified as an anomaly.

## Thresholds

Warning:

- Relative increase at least 30%
- Absolute increase at least $100

Critical:

- Relative increase at least 100%
- Absolute increase at least $500

Both the relative and absolute conditions must be met.

## Investigation status

Controlled values:

- Open
- Investigating
- Resolved
- Accepted

Accepted means the cost movement was confirmed as expected or intentional,
such as a planned product launch.

## False-positive limitations

The detector can still flag expected events such as:

- Planned product launches
- Approved load tests
- Planned migrations
- Scheduled AI training jobs
- New services without communicated baselines
- Temporary business promotions

The detector identifies unexpected statistical behavior. It does not know
whether the business intended the activity.

A human owner must review material findings before any optimization or
remediation action is taken.

## False-negative limitations

The detector may not identify:

- Slow cost growth spread across many days
- Anomalies below the $100 absolute threshold
- New resources without seven days of history
- Cost increases hidden by an offsetting credit
- Operational problems that do not materially change billed cost

## Financial control

The complete daily financial series reconciles to
`retail_finops_core.fct_cloud_cost`.

Each anomaly's positive Usage cost reconciles to the contributing records
in `fct_anomaly_source_detail`.

No balancing adjustments are permitted.
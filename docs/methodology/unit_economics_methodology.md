# Business Unit Economics Methodology

## Purpose

Connect Retail Co.'s modeled cloud cost to modeled retail business activity.

The unit-economics layer explains not only how much cloud cost changed, but
whether the cost of serving each business unit improved or deteriorated.

## Business-activity source

Source file:

`data/business_activity/business_activity.csv`

Generation method:

- Deterministic synthetic generator
- Seed 42
- One row per workload per day
- Period: July 1, 2025 through June 30, 2026
- Monthly growth
- Monthly seasonality
- Production and non-production weekend patterns
- Log-normal daily variation

The file contains:

- Traffic
- Transactions
- Queries
- Support requests
- AI requests
- API requests
- Active customers
- Revenue

All activity is synthetic and must remain labeled synthetic.

## Cost source

Cost comes from:

`retail_finops_core.fct_cost_allocation`

This means:

- Direct cost remains with the source application.
- Shared-platform cost is assigned to consuming applications.
- Unallocated cost remains explicitly unallocated.
- Credits and refunds remain included in allocated financial cost.

## Application unit-economics numerator

Application numerator:

`Total allocated cloud cost for the application`

This includes production and non-production cost assigned to the application.

## Application business-activity denominator

Business activity uses production workloads.

This avoids presenting non-production test traffic as external customer
business activity.

## Portfolio numerator

Portfolio numerator:

`Complete allocated cloud cost`

This includes:

- Production cost
- Non-production cost
- Shared allocated cost
- Unallocated cost

## Portfolio denominator

Portfolio business activity includes production activity for customer-facing
applications.

Shared Platform and Unallocated are excluded from the denominator because
they do not represent independent customer-value units.

## Core formulas

### Cost per transaction

`Total allocated cost / Transactions`

### Cost per active customer

`Total allocated cost / Average daily active customers`

The synthetic dataset contains daily active-customer estimates, not a
deduplicated monthly active-customer identifier.

Therefore, the calculation uses average daily active customers and records:

`active_customer_basis = AVERAGE_DAILY_ACTIVE_CUSTOMERS`

It must not be described as deduplicated monthly active customers.

### Cost per API request

`Total allocated cost / API requests`

### Infrastructure cost as percentage of revenue

`Total allocated cost / Revenue`

Display this result as a percentage in Excel and Power BI.

## Interpretation

Rising total cost does not automatically mean poor unit economics.

Example:

- Cost increases 8%
- Transactions increase 15%
- Cost per transaction falls 6%

Interpretation:

The platform costs more in total because it serves more demand, but it has
become more efficient per transaction.

Poor unit economics occur when cloud cost grows faster than the business
units supported.

## Data limitations

The business activity is synthetic.

Revenue is modeled as part of the deterministic activity generator and is
not Retail Co. actual revenue.

Active customers are daily estimates and are not deduplicated real customer
identities.

The project demonstrates the cost-side methodology and control process. It
does not claim real company profitability, ROI or customer value.

## Permitted interview wording

"The platform connected modeled allocated cloud cost to deterministic retail
business activity and calculated reproducible cost per transaction, active
customer and API request. It also distinguished total-cost growth from
unit-cost deterioration."

## Prohibited wording

"Retail Co.'s real customer profitability improved by the modeled amount."

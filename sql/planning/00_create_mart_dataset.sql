/*
Purpose:
    Create the analytical-mart dataset used by financial planning,
    variance analysis and monthly close.

Grain:
    Dataset creation only.

Source:
    None.

Key controls:
    Dataset creation is idempotent.

Owner:
    FinOps.

Refresh:
    One-time setup; safe to rerun.
*/

CREATE SCHEMA IF NOT EXISTS
    `__PROJECT_ID__.retail_finops_mart`;
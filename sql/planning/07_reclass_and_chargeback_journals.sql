/*
Purpose:
    Create balanced reclass and chargeback journals.

Reclass:
    Moves shared-platform cost from its source cost center to the
    allocation target cost center.

Chargeback:
    Posts allocated cloud cost to the consuming cost center and
    offsets it against a cloud-cost clearing account.

Grain:
    One row per accounting journal line.

Source:
    retail_finops_core.fct_cost_allocation

Key controls:
    - Every journal contains two lines.
    - Every journal nets to zero.
    - Target chargeback lines reconcile to allocated cost.
    - Negative credits reverse normal debit/credit direction.
    - Source lineage remains available.

Owner:
    Finance and FinOps.

Refresh:
    After allocation refresh.
*/

CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_reclass_journal`

PARTITION BY journal_month

CLUSTER BY
    provider_name,
    journal_id,
    posting_cost_center

AS

WITH shared_allocation AS (
    SELECT
        allocation_id,
        record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        billing_month AS journal_month,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        COALESCE(
            NULLIF(TRIM(source_cost_center), ''),
            'Shared Platform'
        ) AS source_cost_center,

        COALESCE(
            NULLIF(TRIM(target_cost_center), ''),
            'Unallocated'
        ) AS target_cost_center,

        target_application_name,
        target_department_name,
        target_environment_name,
        target_owner_name,

        billing_currency,
        allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`

    WHERE allocation_method = 'SHARED_PROPORTIONAL'
),

journal_lines AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|SHARED_RECLASS'
                )
            )
        ) AS journal_id,

        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|SHARED_RECLASS|TARGET'
                )
            )
        ) AS journal_line_id,

        journal_month,
        allocation_id,
        record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        target_cost_center
            AS posting_cost_center,

        source_cost_center
            AS counterparty_cost_center,

        target_application_name
            AS application_name,

        target_department_name
            AS department_name,

        target_environment_name
            AS environment_name,

        target_owner_name
            AS owner_name,

        CASE
            WHEN allocated_cost >= 0
            THEN 'DEBIT'
            ELSE 'CREDIT'
        END AS journal_line_type,

        CAST(
            allocated_cost
            AS NUMERIC
        ) AS journal_amount,

        billing_currency,

        'SHARED_PLATFORM_ALLOCATION_RECLASS'
            AS journal_reason,

        'POSTED' AS journal_status,

        CURRENT_TIMESTAMP()
            AS data_refresh_timestamp

    FROM shared_allocation

    UNION ALL

    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|SHARED_RECLASS'
                )
            )
        ),

        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|SHARED_RECLASS|SOURCE'
                )
            )
        ),

        journal_month,
        allocation_id,
        record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        source_cost_center,
        target_cost_center,

        'Shared Platform',
        'Shared Platform',
        'Shared Platform',
        'Shared Platform',

        CASE
            WHEN allocated_cost >= 0
            THEN 'CREDIT'
            ELSE 'DEBIT'
        END,

        CAST(
            -allocated_cost
            AS NUMERIC
        ),

        billing_currency,

        'SHARED_PLATFORM_ALLOCATION_RECLASS',

        'POSTED',

        CURRENT_TIMESTAMP()

    FROM shared_allocation
)

SELECT
    journal_id,
    journal_line_id,
    journal_month,

    allocation_id,
    record_id,
    source_record_id,
    pipeline_run_id,
    source_system,
    source_file,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    posting_cost_center,
    counterparty_cost_center,

    application_name,
    department_name,
    environment_name,
    owner_name,

    journal_line_type,
    journal_amount,
    billing_currency,

    journal_reason,
    journal_status,
    data_refresh_timestamp

FROM journal_lines;


CREATE OR REPLACE TABLE
    `__PROJECT_ID__.retail_finops_mart.fct_chargeback_journal`

PARTITION BY journal_month

CLUSTER BY
    provider_name,
    journal_id,
    posting_account

AS

WITH allocation_rows AS (
    SELECT
        allocation_id,
        record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        billing_month AS journal_month,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        COALESCE(
            NULLIF(TRIM(target_application_name), ''),
            'Unallocated'
        ) AS application_name,

        COALESCE(
            NULLIF(TRIM(target_department_name), ''),
            'Unallocated'
        ) AS department_name,

        COALESCE(
            NULLIF(TRIM(target_environment_name), ''),
            'Unallocated'
        ) AS environment_name,

        COALESCE(
            NULLIF(TRIM(target_cost_center), ''),
            'Unallocated'
        ) AS cost_center,

        COALESCE(
            NULLIF(TRIM(target_owner_name), ''),
            'Unallocated'
        ) AS owner_name,

        allocation_method,
        billing_currency,
        allocated_cost

    FROM
        `__PROJECT_ID__.retail_finops_core.fct_cost_allocation`
),

journal_lines AS (
    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|CHARGEBACK'
                )
            )
        ) AS journal_id,

        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|CHARGEBACK|TARGET'
                )
            )
        ) AS journal_line_id,

        journal_month,

        allocation_id,
        record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        cost_center AS posting_account,
        'CLOUD_COST_CLEARING'
            AS counterparty_account,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        allocation_method,

        'TARGET_COST_CENTER'
            AS journal_line_role,

        CASE
            WHEN allocated_cost >= 0
            THEN 'DEBIT'
            ELSE 'CREDIT'
        END AS journal_line_type,

        CAST(
            allocated_cost
            AS NUMERIC
        ) AS journal_amount,

        billing_currency,

        'CLOUD_COST_CHARGEBACK'
            AS journal_reason,

        'POSTED' AS journal_status,

        CURRENT_TIMESTAMP()
            AS data_refresh_timestamp

    FROM allocation_rows

    UNION ALL

    SELECT
        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|CHARGEBACK'
                )
            )
        ),

        TO_HEX(
            SHA256(
                CONCAT(
                    allocation_id,
                    '|CHARGEBACK|CLEARING'
                )
            )
        ),

        journal_month,

        allocation_id,
        record_id,
        source_record_id,
        pipeline_run_id,
        source_system,
        source_file,

        provider_name,
        billing_account_id,
        sub_account_id,
        project_id,

        'CLOUD_COST_CLEARING',
        cost_center,

        application_name,
        department_name,
        environment_name,
        cost_center,
        owner_name,

        allocation_method,

        'CLEARING_ACCOUNT',

        CASE
            WHEN allocated_cost >= 0
            THEN 'CREDIT'
            ELSE 'DEBIT'
        END,

        CAST(
            -allocated_cost
            AS NUMERIC
        ),

        billing_currency,

        'CLOUD_COST_CHARGEBACK',

        'POSTED',

        CURRENT_TIMESTAMP()

    FROM allocation_rows
)

SELECT
    journal_id,
    journal_line_id,
    journal_month,

    allocation_id,
    record_id,
    source_record_id,
    pipeline_run_id,
    source_system,
    source_file,

    provider_name,
    billing_account_id,
    sub_account_id,
    project_id,

    posting_account,
    counterparty_account,

    application_name,
    department_name,
    environment_name,
    cost_center,
    owner_name,

    allocation_method,
    journal_line_role,
    journal_line_type,
    journal_amount,
    billing_currency,

    journal_reason,
    journal_status,
    data_refresh_timestamp

FROM journal_lines;

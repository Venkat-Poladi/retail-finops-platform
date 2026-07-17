-- Purpose: Reconcile each provider and the post-conformance union back to source financial controls.

CREATE OR REPLACE TABLE focus_reconciliation AS
WITH aws_source AS (
    SELECT
        COUNT(*)::BIGINT AS source_rows,
        SUM(CAST(line_item_unblended_cost AS DOUBLE)) AS source_billed_cost
    FROM raw_aws_billing
),
aws_focus AS (
    SELECT
        COUNT(*)::BIGINT AS focus_rows,
        SUM(billed_cost) AS focus_billed_cost
    FROM stg_aws_focus
),
gcp_source AS (
    SELECT
        COUNT(*)::BIGINT AS source_rows,
        SUM(CAST(cost AS DOUBLE)) AS source_cost_before_credits,
        SUM(
            COALESCE(
                list_sum(list_transform(credits, item -> item.amount)),
                0.0
            )
        ) AS source_credit_total
    FROM raw_gcp_billing
),
gcp_focus AS (
    SELECT
        COUNT(*) FILTER (WHERE charge_category <> 'Credit')::BIGINT AS parent_rows,
        COUNT(*) FILTER (WHERE charge_category = 'Credit')::BIGINT AS credit_rows,
        SUM(billed_cost) AS focus_billed_cost
    FROM stg_gcp_focus
),
provider_controls AS (
    SELECT
        'AWS' AS provider_name,
        'BILLED_COST' AS control_name,
        aws_source.source_billed_cost AS source_value,
        aws_focus.focus_billed_cost AS normalized_value
    FROM aws_source, aws_focus

    UNION ALL

    SELECT
        'GCP' AS provider_name,
        'NET_COST' AS control_name,
        gcp_source.source_cost_before_credits
            + gcp_source.source_credit_total AS source_value,
        gcp_focus.focus_billed_cost AS normalized_value
    FROM gcp_source, gcp_focus

    UNION ALL

    SELECT
        'ALL_CLOUD' AS provider_name,
        'NET_COST' AS control_name,
        aws_source.source_billed_cost
            + gcp_source.source_cost_before_credits
            + gcp_source.source_credit_total AS source_value,
        (SELECT SUM(billed_cost) FROM stg_focus_union) AS normalized_value
    FROM aws_source, gcp_source
)
SELECT
    provider_name,
    control_name,
    ROUND(source_value, 6) AS source_value,
    ROUND(normalized_value, 6) AS normalized_value,
    ROUND(normalized_value - source_value, 6) AS variance,
    ROUND(GREATEST(0.01, ABS(source_value) * 0.000001), 6) AS tolerance,
    CASE
        WHEN ABS(normalized_value - source_value)
            <= GREATEST(0.01, ABS(source_value) * 0.000001)
        THEN 'PASS'
        ELSE 'FAIL'
    END AS status
FROM provider_controls;

CREATE OR REPLACE TABLE focus_row_controls AS
WITH aws_source AS (
    SELECT COUNT(*)::BIGINT AS source_rows FROM raw_aws_billing
),
aws_focus AS (
    SELECT COUNT(*)::BIGINT AS focus_rows FROM stg_aws_focus
),
gcp_source AS (
    SELECT
        COUNT(*)::BIGINT AS source_rows,
        SUM(len(credits))::BIGINT AS nested_credit_elements
    FROM raw_gcp_billing
),
gcp_focus AS (
    SELECT
        COUNT(*) FILTER (WHERE charge_category <> 'Credit')::BIGINT AS parent_rows,
        COUNT(*) FILTER (WHERE charge_category = 'Credit')::BIGINT AS credit_rows
    FROM stg_gcp_focus
)
SELECT
    'AWS_SOURCE_TO_FOCUS_ROWS' AS control_name,
    aws_source.source_rows AS expected_value,
    aws_focus.focus_rows AS actual_value,
    CASE WHEN aws_source.source_rows = aws_focus.focus_rows
        THEN 'PASS' ELSE 'FAIL' END AS status
FROM aws_source, aws_focus

UNION ALL

SELECT
    'GCP_PARENT_ROWS' AS control_name,
    gcp_source.source_rows AS expected_value,
    gcp_focus.parent_rows AS actual_value,
    CASE WHEN gcp_source.source_rows = gcp_focus.parent_rows
        THEN 'PASS' ELSE 'FAIL' END AS status
FROM gcp_source, gcp_focus

UNION ALL

SELECT
    'GCP_CREDIT_ROWS' AS control_name,
    gcp_source.nested_credit_elements AS expected_value,
    gcp_focus.credit_rows AS actual_value,
    CASE WHEN gcp_source.nested_credit_elements = gcp_focus.credit_rows
        THEN 'PASS' ELSE 'FAIL' END AS status
FROM gcp_source, gcp_focus;

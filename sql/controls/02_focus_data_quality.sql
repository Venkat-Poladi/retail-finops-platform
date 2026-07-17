-- Purpose: Summarize staging quality without deleting or silently correcting source exceptions.

CREATE OR REPLACE TABLE focus_data_quality_summary AS
SELECT
    provider_name,
    COUNT(*)::BIGINT AS total_focus_rows,
    COUNT(*) FILTER (WHERE is_duplicate)::BIGINT AS duplicate_rows,
    COUNT(*) FILTER (
        WHERE source_data_quality_status = 'INVALID_NEGATIVE_USAGE'
    )::BIGINT AS invalid_rows,
    COUNT(*) FILTER (WHERE allocation_status = 'Unallocated')::BIGINT AS unallocated_rows,
    COUNT(*) FILTER (WHERE is_late_arriving)::BIGINT AS late_arriving_rows,
    COUNT(*) FILTER (
        WHERE is_valid_for_financial_reporting
    )::BIGINT AS valid_canonical_rows,
    ROUND(SUM(billed_cost), 6) AS total_billed_cost,
    ROUND(SUM(
        CASE WHEN is_valid_for_financial_reporting
            THEN billed_cost ELSE 0.0 END
    ), 6) AS valid_canonical_billed_cost
FROM stg_focus_union
GROUP BY provider_name
ORDER BY provider_name;

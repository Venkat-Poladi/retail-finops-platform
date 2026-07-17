-- Purpose: Union provider rows only after both source systems conform to an identical schema.

CREATE OR REPLACE TABLE stg_focus_union AS
SELECT * FROM stg_aws_focus
UNION ALL
SELECT * FROM stg_gcp_focus;

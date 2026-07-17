"""Run SQL-first provider normalization and reconciliation with DuckDB.

All source-to-FOCUS mapping logic lives in SQL files. This Python module only:
1. registers source/config files as DuckDB views,
2. executes the SQL in order,
3. exports reviewable outputs,
4. writes a compact validation summary.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import duckdb


def _sql_literal(path: Path) -> str:
    """Return a safely quoted filesystem path for SQL statements."""
    return str(path.resolve()).replace("'", "''")


def _execute_sql_file(connection: duckdb.DuckDBPyConnection, path: Path) -> None:
    """Execute one SQL file."""
    connection.execute(path.read_text(encoding="utf-8"))


def _export_table(
    connection: duckdb.DuckDBPyConnection,
    table_name: str,
    output_file: Path,
) -> None:
    """Export a DuckDB table to CSV with a header."""
    output_file.parent.mkdir(parents=True, exist_ok=True)
    connection.execute(
        f"COPY {table_name} TO '{_sql_literal(output_file)}' "
        "(HEADER, DELIMITER ',')"
    )


def run_focus_normalization(root: Path) -> dict[str, Any]:
    """Normalize AWS and GCP independently, union after conformance, reconcile."""
    root = root.resolve()
    aws_file = (
        root
        / "data"
        / "synthetic_enterprise_usage"
        / "aws"
        / "aws_billing.csv"
    )
    gcp_file = (
        root
        / "data"
        / "synthetic_enterprise_usage"
        / "gcp"
        / "gcp_billing.jsonl"
    )
    aws_accounts = root / "config" / "aws_accounts.csv"

    missing_files = [
        path
        for path in (aws_file, gcp_file, aws_accounts)
        if not path.exists()
    ]
    if missing_files:
        missing_text = "\n".join(str(path) for path in missing_files)
        raise FileNotFoundError(
            "Required Milestone 3/4 inputs are missing:\n" + missing_text
        )

    output_dir = root / "data" / "focus_staging"
    output_dir.mkdir(parents=True, exist_ok=True)

    connection = duckdb.connect(database=":memory:")
    try:
        connection.execute(
            f"""
            CREATE VIEW raw_aws_billing AS
            SELECT
                ROW_NUMBER() OVER () AS source_row_number,
                *
            FROM read_csv_auto(
                '{_sql_literal(aws_file)}',
                header = true,
                all_varchar = false,
                sample_size = -1
            );
            """
        )
        connection.execute(
            f"""
            CREATE VIEW raw_gcp_billing AS
            SELECT
                ROW_NUMBER() OVER () AS source_row_number,
                *
            FROM read_json_auto(
                '{_sql_literal(gcp_file)}',
                format = 'newline_delimited',
                sample_size = -1
            );
            """
        )
        connection.execute(
            f"""
            CREATE VIEW aws_accounts_config AS
            SELECT *
            FROM read_csv_auto(
                '{_sql_literal(aws_accounts)}',
                header = true,
                all_varchar = true
            );
            """
        )

        sql_files = [
            root / "sql" / "staging" / "01_aws_focus.sql",
            root / "sql" / "staging" / "02_gcp_focus.sql",
            root / "sql" / "staging" / "03_focus_union.sql",
            root / "sql" / "controls" / "01_focus_reconciliation.sql",
            root / "sql" / "controls" / "02_focus_data_quality.sql",
        ]
        for sql_file in sql_files:
            _execute_sql_file(connection, sql_file)

        exports = {
            "aws_focus": ("stg_aws_focus", output_dir / "aws_focus.csv"),
            "gcp_focus": ("stg_gcp_focus", output_dir / "gcp_focus.csv"),
            "focus_union": ("stg_focus_union", output_dir / "focus_union.csv"),
            "reconciliation": (
                "focus_reconciliation",
                output_dir / "focus_reconciliation.csv",
            ),
            "row_controls": (
                "focus_row_controls",
                output_dir / "focus_row_controls.csv",
            ),
            "data_quality": (
                "focus_data_quality_summary",
                output_dir / "focus_data_quality_summary.csv",
            ),
        }
        for table_name, output_file in exports.values():
            _export_table(connection, table_name, output_file)

        provider_rows = {
            row[0]: int(row[1])
            for row in connection.execute(
                """
                SELECT provider_name, COUNT(*)
                FROM stg_focus_union
                GROUP BY provider_name
                ORDER BY provider_name
                """
            ).fetchall()
        }
        charge_categories = {
            row[0]: int(row[1])
            for row in connection.execute(
                """
                SELECT charge_category, COUNT(*)
                FROM stg_focus_union
                GROUP BY charge_category
                ORDER BY charge_category
                """
            ).fetchall()
        }
        reconciliation_rows = connection.execute(
            """
            SELECT provider_name, control_name, source_value,
                   normalized_value, variance, tolerance, status
            FROM focus_reconciliation
            ORDER BY provider_name
            """
        ).fetchall()
        row_control_rows = connection.execute(
            """
            SELECT control_name, expected_value, actual_value, status
            FROM focus_row_controls
            ORDER BY control_name
            """
        ).fetchall()

        all_reconciliations_pass = all(
            row[-1] == "PASS" for row in reconciliation_rows
        )
        all_row_controls_pass = all(
            row[-1] == "PASS" for row in row_control_rows
        )

        summary: dict[str, Any] = {
            "overall_status": (
                "PASS"
                if all_reconciliations_pass and all_row_controls_pass
                else "FAIL"
            ),
            "normalization_approach": "SQL_FIRST_DUCKDB_LOCAL",
            "aws_normalized_independently": True,
            "gcp_normalized_independently": True,
            "source_rows_combined_before_conformance": False,
            "providers_unioned_after_conformance": True,
            "provider_focus_row_counts": provider_rows,
            "total_focus_rows": int(sum(provider_rows.values())),
            "charge_category_counts": charge_categories,
            "reconciliation_controls": [
                {
                    "provider_name": row[0],
                    "control_name": row[1],
                    "source_value": float(row[2]),
                    "normalized_value": float(row[3]),
                    "variance": float(row[4]),
                    "tolerance": float(row[5]),
                    "status": row[6],
                }
                for row in reconciliation_rows
            ],
            "row_controls": [
                {
                    "control_name": row[0],
                    "expected_value": int(row[1]),
                    "actual_value": int(row[2]),
                    "status": row[3],
                }
                for row in row_control_rows
            ],
            "gcp_credit_handling": (
                "One child FOCUS credit row per nested GCP credit. "
                "Labels are extracted without cross-joining the credit array."
            ),
            "schema_note": (
                "This is the project FOCUS-aligned staging schema, not a claim "
                "of complete certification against every optional FOCUS field."
            ),
        }
        summary_file = output_dir / "focus_validation_summary.json"
        summary_file.write_text(
            json.dumps(summary, indent=2, sort_keys=True),
            encoding="utf-8",
        )
        return summary
    finally:
        connection.close()


def main() -> None:
    """CLI entry point."""
    root = Path(__file__).resolve().parents[1]
    summary = run_focus_normalization(root)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

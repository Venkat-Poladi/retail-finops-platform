from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# These files support the local DuckDB normalization workflow.
DUCKDB_SQL = {
    Path("sql/controls/01_focus_reconciliation.sql"),
    Path("sql/staging/01_aws_focus.sql"),
    Path("sql/staging/02_gcp_focus.sql"),
}


def run_lint(
    dialect: str,
    files: list[Path],
    label: str,
) -> None:
    if not files:
        return

    print(f"\n{'=' * 72}")
    print(label)
    print("=" * 72)
    print(f"Dialect: {dialect}")
    print(f"Files: {len(files)}")

    command = [
        sys.executable,
        "-m",
        "sqlfluff",
        "lint",
        "--dialect",
        dialect,
        "--config",
        ".sqlfluff",
        "--disable-progress-bar",
        *[path.as_posix() for path in files],
    ]

    result = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
    )

    if result.returncode != 0:
        raise SystemExit(
            f"{label} failed with exit code {result.returncode}."
        )


def main() -> None:
    all_sql_files = sorted(
        path.relative_to(ROOT)
        for path in (ROOT / "sql").rglob("*.sql")
    )

    all_sql_set = set(all_sql_files)

    missing_duckdb_files = sorted(
        DUCKDB_SQL - all_sql_set
    )

    if missing_duckdb_files:
        missing = "\n".join(
            f"  {path.as_posix()}"
            for path in missing_duckdb_files
        )
        raise SystemExit(
            "Expected DuckDB SQL files were not found:\n"
            f"{missing}"
        )

    bigquery_files = [
        path
        for path in all_sql_files
        if path not in DUCKDB_SQL
    ]

    duckdb_files = sorted(DUCKDB_SQL)

    run_lint(
        dialect="bigquery",
        files=bigquery_files,
        label="Linting BigQuery SQL",
    )

    run_lint(
        dialect="duckdb",
        files=duckdb_files,
        label="Linting local DuckDB SQL",
    )

    print(
        "\nSQL lint: PASS"
        f"\n- BigQuery files: {len(bigquery_files)}"
        f"\n- DuckDB files: {len(duckdb_files)}"
        f"\n- Total SQL files: {len(all_sql_files)}"
    )


if __name__ == "__main__":
    main()

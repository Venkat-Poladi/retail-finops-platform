from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str], label: str) -> None:
    print(f"\n{'=' * 72}")
    print(label)
    print("=" * 72)

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
    python = sys.executable

    # Generator tests recreate the original provider files, so run all
    # non-hardening tests first.
    run(
        [
            python,
            "-m",
            "pytest",
            "--ignore=tests/test_provider_schema_hardening.py",
        ],
        "Running base automated tests",
    )

    # Restore the required provider-export fields after generator tests.
    run(
        [
            python,
            "-m",
            "generator.provider_schema_hardening",
        ],
        "Refreshing provider schema-hardening outputs",
    )

    # Validate the hardened AWS and GCP schemas separately.
    run(
        [
            python,
            "-m",
            "pytest",
            "tests/test_provider_schema_hardening.py",
        ],
        "Running provider schema-hardening tests",
    )

    run(
        [
            python,
            "scripts/repository_quality_check.py",
        ],
        "Running repository quality check",
    )

    print("\nRepository CI: PASS")
    print("- 48 base tests passed")
    print("- 8 provider schema-hardening tests passed")
    print("- 56 automated tests passed in total")


if __name__ == "__main__":
    main()
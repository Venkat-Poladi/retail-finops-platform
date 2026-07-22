from __future__ import annotations

import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class TestCounts:
    tests: int
    failures: int
    errors: int
    skipped: int

    @property
    def passed(self) -> int:
        return (
            self.tests
            - self.failures
            - self.errors
            - self.skipped
        )

    def __add__(self, other: "TestCounts") -> "TestCounts":
        return TestCounts(
            tests=self.tests + other.tests,
            failures=self.failures + other.failures,
            errors=self.errors + other.errors,
            skipped=self.skipped + other.skipped,
        )


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
            f"{label} failed with exit code "
            f"{result.returncode}."
        )


def read_pytest_counts(report_path: Path) -> TestCounts:
    root = ET.parse(report_path).getroot()

    if root.tag == "testsuite":
        suites = [root]
    else:
        suites = list(root.findall("./testsuite"))

    if not suites:
        raise RuntimeError(
            f"No pytest results found in {report_path}."
        )

    return TestCounts(
        tests=sum(
            int(suite.attrib.get("tests", 0))
            for suite in suites
        ),
        failures=sum(
            int(suite.attrib.get("failures", 0))
            for suite in suites
        ),
        errors=sum(
            int(suite.attrib.get("errors", 0))
            for suite in suites
        ),
        skipped=sum(
            int(suite.attrib.get("skipped", 0))
            for suite in suites
        ),
    )


def run_pytest(
    arguments: list[str],
    label: str,
    report_path: Path,
) -> TestCounts:
    run(
        [
            sys.executable,
            "-m",
            "pytest",
            *arguments,
            f"--junitxml={report_path}",
        ],
        label,
    )

    return read_pytest_counts(report_path)


def main() -> None:
    python = sys.executable

    with tempfile.TemporaryDirectory(
        prefix="retail-finops-ci-"
    ) as temporary_directory:
        temporary_path = Path(temporary_directory)

        base_counts = run_pytest(
            [
                "--ignore="
                "tests/test_provider_schema_hardening.py",
            ],
            "Running base automated tests",
            temporary_path / "base-tests.xml",
        )

        # Generator tests recreate the original provider files.
        # Refresh the hardened outputs before validating them.
        run(
            [
                python,
                "-m",
                "generator.provider_schema_hardening",
            ],
            "Refreshing provider schema-hardening outputs",
        )

        hardening_counts = run_pytest(
            [
                "tests/test_provider_schema_hardening.py",
            ],
            "Running provider schema-hardening tests",
            temporary_path / "hardening-tests.xml",
        )

        run(
            [
                python,
                "scripts/lint_sql.py",
            ],
            "Running SQL validation",
        )

        run(
            [
                python,
                "scripts/repository_quality_check.py",
            ],
            "Running repository quality check",
        )

        total = base_counts + hardening_counts

        print("\nRepository CI: PASS")
        print(
            "Pytest summary: "
            f"{total.passed} passed, "
            f"{total.skipped} skipped, "
            f"{total.failures} failed, "
            f"{total.errors} errors, "
            f"{total.tests} collected"
        )


if __name__ == "__main__":
    main()

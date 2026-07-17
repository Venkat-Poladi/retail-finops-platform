"""Run lightweight packaging and repository-hygiene checks."""

from __future__ import annotations

from pathlib import Path
import json
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = [
    ROOT / "README.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "docs" / "architecture" / "current_architecture.md",
    ROOT / "docs" / "screenshots" / "screenshot_checklist.md",
    ROOT / "data" / "source_validation" / "source_validation_summary.json",
    ROOT / "data" / "focus_staging" / "focus_validation_summary.json",
    ROOT / "data" / "focus_staging" / "focus_reconciliation.csv",
]

FORBIDDEN_TRACKED_PARTS = {
    ".env",
    ".venv",
    ".coverage",
    "__pycache__",
    ".pytest_cache",
    "htmlcov",
    "Thumbs.db",
    ".DS_Store",
}

FORBIDDEN_BILLING_OUTPUTS = {
    "combined_billing.csv",
    "unified_billing.csv",
    "synthetic_billing_unified.csv",
}


def tracked_files() -> list[Path]:
    """Return Git-tracked paths, or regular files when outside a Git checkout."""
    result = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return [ROOT / line for line in result.stdout.splitlines() if line.strip()]
    return [path for path in ROOT.rglob("*") if path.is_file()]


def main() -> int:
    errors: list[str] = []

    for required_file in REQUIRED_FILES:
        if not required_file.exists():
            errors.append(f"Missing required file: {required_file.relative_to(ROOT)}")

    for path in tracked_files():
        relative = path.relative_to(ROOT)
        if any(part in FORBIDDEN_TRACKED_PARTS for part in relative.parts):
            errors.append(f"Forbidden tracked artifact: {relative}")
        if path.name in FORBIDDEN_BILLING_OUTPUTS:
            errors.append(f"Premature combined billing output: {relative}")

    focus_summary_path = ROOT / "data" / "focus_staging" / "focus_validation_summary.json"
    if focus_summary_path.exists():
        summary = json.loads(focus_summary_path.read_text(encoding="utf-8"))
        if summary.get("overall_status") != "PASS":
            errors.append("FOCUS validation summary is not PASS")
        if summary.get("source_rows_combined_before_conformance") is not False:
            errors.append("Source rows were combined before conformance")
        if summary.get("providers_unioned_after_conformance") is not True:
            errors.append("Providers were not unioned after conformance")

    source_summary_path = ROOT / "data" / "source_validation" / "source_validation_summary.json"
    if source_summary_path.exists():
        summary = json.loads(source_summary_path.read_text(encoding="utf-8"))
        if summary.get("billing_rows_were_combined") is not False:
            errors.append("Source validation indicates provider rows were combined")

    if errors:
        print("Repository quality check: FAIL")
        for error in errors:
            print(f"- {error}")
        return 1

    print("Repository quality check: PASS")
    print("- Required documentation and evidence exist")
    print("- No forbidden artifacts are tracked")
    print("- No premature combined billing files exist")
    print("- Provider union occurs only after conformance")
    print("- FOCUS-aligned reconciliation status is PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

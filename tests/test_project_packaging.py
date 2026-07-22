"""Tests for final packaging of the complete Retail FinOps platform."""

from pathlib import Path
import json


ROOT = Path(__file__).resolve().parents[1]


def test_readme_describes_current_platform_scope() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    normalized = " ".join(readme.lower().split())

    required_phrases = {
        "deterministic synthetic data",
        "cost allocation",
        "forecasting",
        "anomaly detection",
        "optimization",
        "unit economics",
        "power bi",
    }

    for phrase in required_phrases:
        assert phrase in normalized, (
            f"README is missing current-platform evidence: {phrase}"
        )

    assert "$188,009.96" in readme

    # Excel was not used as a project output.
    assert "excel financial model" not in normalized
    assert "excel/" not in normalized

    stale_claims = {
        "this repository currently demonstrates the controlled synthetic billing "
        "and normalization foundation only",
        "power bi is the next development milestone",
    }

    for stale_claim in stale_claims:
        assert stale_claim not in normalized, (
            f"README still contains an outdated claim: {stale_claim}"
        )


def test_architecture_preserves_independent_provider_paths() -> None:
    architecture = (
        ROOT / "docs" / "architecture" / "current_architecture.md"
    ).read_text(encoding="utf-8")

    assert "AWS source validation" in architecture
    assert "GCP source validation" in architecture
    assert "Post-conformance UNION ALL" in architecture
    assert "AWS usage account is not presented" in architecture


def test_required_control_evidence_exists() -> None:
    required_files = [
        ROOT / "data" / "source_validation" / "source_validation_summary.json",
        ROOT / "data" / "focus_staging" / "focus_validation_summary.json",
        ROOT / "data" / "focus_staging" / "focus_reconciliation.csv",
    ]

    assert all(path.exists() for path in required_files)


def test_focus_summary_is_reconciled_and_post_conformance() -> None:
    path = ROOT / "data" / "focus_staging" / "focus_validation_summary.json"
    summary = json.loads(path.read_text(encoding="utf-8"))

    assert summary["overall_status"] == "PASS"
    assert summary["source_rows_combined_before_conformance"] is False
    assert summary["providers_unioned_after_conformance"] is True
    assert all(
        control["variance"] == 0
        for control in summary["reconciliation_controls"]
    )


def test_no_premature_combined_source_billing_files_exist() -> None:
    forbidden_names = {
        "combined_billing.csv",
        "unified_billing.csv",
        "synthetic_billing_unified.csv",
    }

    existing_names = {path.name for path in ROOT.rglob("*") if path.is_file()}
    assert forbidden_names.isdisjoint(existing_names)


def test_development_integrity_standard_is_documented() -> None:
    contributing = (ROOT / "CONTRIBUTING.md").read_text(encoding="utf-8")

    assert "meaningful improvement" in contributing
    assert "Alter author or committer dates" in contributing
    assert "Create empty or meaningless commits" in contributing

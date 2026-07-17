"""Tests for SQL-first provider normalization and reconciliation."""

from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

from normalization.run_focus_normalization import run_focus_normalization


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "data" / "focus_staging"


def _run() -> dict:
    return run_focus_normalization(ROOT)


def test_provider_outputs_are_created_separately_before_union() -> None:
    summary = _run()

    assert (OUTPUT_DIR / "aws_focus.csv").exists()
    assert (OUTPUT_DIR / "gcp_focus.csv").exists()
    assert (OUTPUT_DIR / "focus_union.csv").exists()
    assert summary["aws_normalized_independently"] is True
    assert summary["gcp_normalized_independently"] is True
    assert summary["source_rows_combined_before_conformance"] is False
    assert summary["providers_unioned_after_conformance"] is True


def test_aws_focus_row_count_matches_aws_source_rows() -> None:
    _run()
    aws_source = pd.read_csv(
        ROOT
        / "data"
        / "synthetic_enterprise_usage"
        / "aws"
        / "aws_billing.csv",
        low_memory=False,
    )
    aws_focus = pd.read_csv(OUTPUT_DIR / "aws_focus.csv", low_memory=False)

    assert len(aws_focus) == len(aws_source)
    assert set(aws_focus["provider_name"]) == {"AWS"}
    assert set(aws_focus["sub_account_type"]) == {"AWS_USAGE_ACCOUNT"}
    assert aws_focus["project_id"].isna().all()


def test_gcp_parent_and_credit_rows_preserve_source_grain() -> None:
    summary = _run()
    gcp_focus = pd.read_csv(OUTPUT_DIR / "gcp_focus.csv", low_memory=False)

    row_controls = {
        item["control_name"]: item for item in summary["row_controls"]
    }
    assert row_controls["GCP_PARENT_ROWS"]["status"] == "PASS"
    assert row_controls["GCP_CREDIT_ROWS"]["status"] == "PASS"
    assert row_controls["GCP_PARENT_ROWS"]["actual_value"] == 17584
    assert row_controls["GCP_CREDIT_ROWS"]["actual_value"] == 1131

    credits = gcp_focus[gcp_focus["charge_category"] == "Credit"]
    assert len(credits) == 1131
    assert credits["parent_record_id"].notna().all()
    assert (credits["billed_cost"] <= 0).all()
    assert set(gcp_focus["sub_account_type"]) == {"GCP_PROJECT"}
    assert gcp_focus["project_id"].notna().sum() > 0


def test_provider_billed_costs_reconcile_to_source_controls() -> None:
    summary = _run()

    assert summary["overall_status"] == "PASS"
    controls = {
        (item["provider_name"], item["control_name"]): item
        for item in summary["reconciliation_controls"]
    }

    assert controls[("AWS", "BILLED_COST")]["status"] == "PASS"
    assert controls[("GCP", "NET_COST")]["status"] == "PASS"
    assert controls[("ALL_CLOUD", "NET_COST")]["status"] == "PASS"
    assert abs(
        controls[("ALL_CLOUD", "NET_COST")]["normalized_value"]
        - 186268.598544
    ) < 0.000001


def test_union_uses_one_identical_schema_for_both_providers() -> None:
    _run()
    aws_focus = pd.read_csv(OUTPUT_DIR / "aws_focus.csv", nrows=1)
    gcp_focus = pd.read_csv(OUTPUT_DIR / "gcp_focus.csv", nrows=1)
    union = pd.read_csv(OUTPUT_DIR / "focus_union.csv", low_memory=False)

    assert list(aws_focus.columns) == list(gcp_focus.columns)
    assert list(union.columns) == list(aws_focus.columns)
    assert set(union["provider_name"]) == {"AWS", "GCP"}
    assert len(union) == 37383


def test_charge_categories_are_common_but_charge_classes_remain_native() -> None:
    _run()
    union = pd.read_csv(OUTPUT_DIR / "focus_union.csv", low_memory=False)

    assert set(union["charge_category"]).issubset(
        {"Usage", "Purchase", "Credit", "Tax", "Adjustment"}
    )

    aws_classes = set(
        union.loc[union["provider_name"] == "AWS", "charge_class"]
    )
    gcp_classes = set(
        union.loc[union["provider_name"] == "GCP", "charge_class"]
    )

    assert "SavingsPlanRecurringFee" in aws_classes
    assert "RIFee" in aws_classes
    assert "COMMITTED_USAGE_DISCOUNT" in gcp_classes
    assert "regular" in gcp_classes
    assert "Credit" not in gcp_classes


def test_duplicates_and_invalid_rows_are_flagged_not_silently_deleted() -> None:
    _run()
    union = pd.read_csv(OUTPUT_DIR / "focus_union.csv", low_memory=False)

    assert int(union["is_duplicate"].sum()) > 0
    assert (
        union["source_data_quality_status"] == "INVALID_NEGATIVE_USAGE"
    ).sum() > 0

    invalid = union[
        union["source_data_quality_status"] == "INVALID_NEGATIVE_USAGE"
    ]
    assert (~invalid["is_valid_for_financial_reporting"]).all()

    duplicate_noncanonical = union[
        union["is_duplicate"] & ~union["is_canonical_record"]
    ]
    assert len(duplicate_noncanonical) > 0
    assert (~duplicate_noncanonical["is_valid_for_financial_reporting"]).all()


def test_missing_tags_and_labels_remain_unallocated() -> None:
    _run()
    union = pd.read_csv(OUTPUT_DIR / "focus_union.csv", low_memory=False)

    missing_business_context = union[
        union["application_name"].isna()
        | union["department_name"].isna()
        | union["environment_name"].isna()
        | union["cost_center"].isna()
    ]

    assert len(missing_business_context) > 0
    assert set(missing_business_context["allocation_status"]) == {
        "Unallocated"
    }


def test_validation_summary_is_saved_and_truthful() -> None:
    summary = _run()
    saved = json.loads(
        (OUTPUT_DIR / "focus_validation_summary.json").read_text(
            encoding="utf-8"
        )
    )

    assert saved == summary
    assert saved["normalization_approach"] == "SQL_FIRST_DUCKDB_LOCAL"
    assert saved["schema_note"].startswith(
        "This is the project FOCUS-aligned staging schema"
    )

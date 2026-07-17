
"""Tests for the AWS synthetic billing generator."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pandas as pd

from generator.aws_billing_generator import generate_aws_billing


ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "config"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _generate(tmp_path: Path) -> tuple[pd.DataFrame, dict]:
    output_dir = tmp_path / "synthetic_enterprise_usage" / "aws"
    summary = generate_aws_billing(CONFIG_DIR, output_dir)
    billing = pd.read_csv(
        output_dir / "aws_billing.csv",
        dtype={
            "bill_payer_account_id": str,
            "line_item_usage_account_id": str,
        },
        low_memory=False,
    )
    return billing, summary


def test_aws_generator_creates_only_aws_outputs(tmp_path: Path) -> None:
    billing, summary = _generate(tmp_path)

    assert not billing.empty
    assert summary["provider"] == "AWS"
    assert (
        tmp_path
        / "synthetic_enterprise_usage"
        / "aws"
        / "aws_billing.csv"
    ).exists()

    assert not list(tmp_path.rglob("*gcp*"))
    assert not list(tmp_path.rglob("*unified*"))
    assert not list(tmp_path.rglob("*combined*"))


def test_aws_history_contains_twelve_complete_months(
    tmp_path: Path,
) -> None:
    billing, summary = _generate(tmp_path)
    usage = billing[
        billing["line_item_line_item_type"].isin(
            ["Usage", "DiscountedUsage", "SavingsPlanCoveredUsage"]
        )
    ].copy()
    usage["usage_date"] = pd.to_datetime(
        usage["line_item_usage_start_date"]
    ).dt.normalize()

    assert usage["usage_date"].min() == pd.Timestamp("2025-07-01")
    assert usage["usage_date"].max() == pd.Timestamp("2026-06-30")
    assert usage["usage_date"].nunique() == 365
    assert usage["usage_date"].dt.to_period("M").nunique() == 12
    assert summary["distinct_usage_dates"] == 365


def test_aws_account_hierarchy_and_native_fields_are_preserved(
    tmp_path: Path,
) -> None:
    billing, _ = _generate(tmp_path)
    accounts = pd.read_csv(
        CONFIG_DIR / "aws_accounts.csv",
        dtype=str,
    )

    required_columns = {
        "bill_payer_account_id",
        "line_item_usage_account_id",
        "line_item_line_item_type",
        "line_item_product_code",
        "line_item_resource_id",
        "pricing_public_on_demand_cost",
        "line_item_unblended_cost",
        "reservation_effective_cost",
        "savings_plan_savings_plan_effective_cost",
        "resource_tags_user_application",
    }

    assert required_columns.issubset(billing.columns)
    assert set(billing["bill_payer_account_id"]) == set(
        accounts["payer_account_id"]
    )
    assert set(billing["line_item_usage_account_id"]).issubset(
        set(accounts["usage_account_id"])
    )
    assert "project_id" not in billing.columns
    assert "billing_account_id" not in billing.columns


def test_aws_charge_types_and_commitments_are_present(
    tmp_path: Path,
) -> None:
    billing, summary = _generate(tmp_path)

    required_types = {
        "Usage",
        "DiscountedUsage",
        "SavingsPlanCoveredUsage",
        "SavingsPlanRecurringFee",
        "RIFee",
        "Fee",
        "Credit",
        "Refund",
    }
    assert required_types.issubset(
        set(billing["line_item_line_item_type"])
    )

    assert set(summary["commitment_profiles"]) == {
        "aws-sp-balanced",
        "aws-sp-under",
        "aws-ri-over",
    }

    assert (
        billing.loc[
            billing["line_item_line_item_type"] == "Credit",
            "line_item_unblended_cost",
        ]
        < 0
    ).all()
    assert (
        billing.loc[
            billing["line_item_line_item_type"] == "Refund",
            "line_item_unblended_cost",
        ]
        < 0
    ).all()


def test_aws_data_quality_scenarios_are_traceable(
    tmp_path: Path,
) -> None:
    billing, summary = _generate(tmp_path)

    assert summary["missing_tag_rows"] > 0
    assert summary["late_arriving_rows"] > 0
    assert summary["invalid_rows"] == 1
    assert summary["duplicated_line_item_ids"] == 2
    assert summary["injected_anomaly_rows"] == 3

    invalid = billing[
        billing["data_quality_status"] == "INVALID_NEGATIVE_USAGE"
    ]
    assert (invalid["line_item_usage_amount"] < 0).all()

    duplicates = billing["line_item_line_item_id"].value_counts()
    assert int((duplicates > 1).sum()) == 2


def test_business_patterns_are_visible(tmp_path: Path) -> None:
    _generate(tmp_path)
    activity = pd.read_csv(
        tmp_path / "business_activity" / "business_activity.csv"
    )
    activity["activity_date"] = pd.to_datetime(
        activity["activity_date"]
    )

    nonprod = activity[activity["environment"] == "nonprod"].copy()
    nonprod["is_weekend"] = (
        nonprod["activity_date"].dt.weekday >= 5
    )

    weekday_mean = nonprod.loc[
        ~nonprod["is_weekend"], "demand_index"
    ].mean()
    weekend_mean = nonprod.loc[
        nonprod["is_weekend"], "demand_index"
    ].mean()

    monthly = activity.groupby(
        activity["activity_date"].dt.month
    )["demand_index"].mean()

    assert weekend_mean < weekday_mean * 0.55
    assert monthly.loc[12] > monthly.loc[1] * 1.4


def test_aws_generation_is_reproducible(tmp_path: Path) -> None:
    first_dir = tmp_path / "first" / "aws"
    second_dir = tmp_path / "second" / "aws"

    first_summary = generate_aws_billing(CONFIG_DIR, first_dir)
    second_summary = generate_aws_billing(CONFIG_DIR, second_dir)

    assert _sha256(first_dir / "aws_billing.csv") == _sha256(
        second_dir / "aws_billing.csv"
    )
    assert first_summary["total_billed_cost"] == second_summary[
        "total_billed_cost"
    ]


def test_aws_control_totals_match_output(tmp_path: Path) -> None:
    billing, summary = _generate(tmp_path)
    summary_file = (
        tmp_path
        / "synthetic_enterprise_usage"
        / "aws"
        / "aws_generator_validation_summary.json"
    )
    saved_summary = json.loads(summary_file.read_text(encoding="utf-8"))

    assert len(billing) == summary["row_count"]
    assert round(billing["line_item_unblended_cost"].sum(), 6) == (
        summary["total_billed_cost"]
    )
    assert round(
        billing["pricing_public_on_demand_cost"].sum(),
        6,
    ) == summary["total_public_on_demand_cost"]
    assert saved_summary == summary

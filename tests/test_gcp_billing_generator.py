"""Tests for the GCP synthetic billing generator."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pandas as pd
import pytest

from generator.gcp_billing_generator import generate_gcp_billing


ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "config"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _read_jsonl(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


@pytest.fixture(scope="module")
def generated(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, list[dict], dict]:
    root = tmp_path_factory.mktemp("gcp_generation")
    output_dir = root / "synthetic_enterprise_usage" / "gcp"
    summary = generate_gcp_billing(CONFIG_DIR, output_dir)
    records = _read_jsonl(output_dir / "gcp_billing.jsonl")
    return root, records, summary


def test_gcp_generator_creates_only_gcp_outputs(
    generated: tuple[Path, list[dict], dict],
) -> None:
    root, records, summary = generated

    assert records
    assert summary["provider"] == "GCP"
    assert summary["source_format"] == "newline_delimited_json"
    assert (
        root
        / "synthetic_enterprise_usage"
        / "gcp"
        / "gcp_billing.jsonl"
    ).exists()

    assert not list(root.rglob("*aws_billing*"))
    assert not list(root.rglob("*unified*"))
    assert not list(root.rglob("*combined*"))


def test_gcp_history_contains_twelve_complete_months(
    generated: tuple[Path, list[dict], dict],
) -> None:
    _, records, summary = generated
    usage_dates = pd.to_datetime(
        [
            record["usage_start_time"]
            for record in records
            if record["cost_type"] == "regular"
            and record["usage"]["amount"] != 0
            and record["service"]["description"]
            != "Google Cloud Marketplace"
        ]
    ).normalize()

    assert usage_dates.min() == pd.Timestamp("2025-07-01")
    assert usage_dates.max() == pd.Timestamp("2026-06-30")
    assert usage_dates.nunique() == 365
    assert usage_dates.to_period("M").nunique() == 12
    assert summary["distinct_usage_dates"] == 365


def test_gcp_billing_hierarchy_and_nested_fields_are_preserved(
    generated: tuple[Path, list[dict], dict],
) -> None:
    _, records, _ = generated
    projects = pd.read_csv(CONFIG_DIR / "gcp_projects.csv", dtype=str)
    usage_records = [
        record
        for record in records
        if record["project"] is not None
        and record["usage"]["amount"] != 0
    ]

    assert {record["billing_account_id"] for record in records} == set(
        projects["billing_account_id"]
    )
    assert {record["project"]["id"] for record in usage_records}.issubset(
        set(projects["project_id"])
    )

    sample = usage_records[0]
    assert isinstance(sample["project"], dict)
    assert isinstance(sample["usage"], dict)
    assert isinstance(sample["labels"], list)
    assert isinstance(sample["credits"], list)
    assert isinstance(sample["price"], dict)
    assert isinstance(sample["invoice"], dict)

    assert "line_item_usage_account_id" not in sample
    assert "bill_payer_account_id" not in sample


def test_gcp_cost_types_nested_credits_and_cuds_are_present(
    generated: tuple[Path, list[dict], dict],
) -> None:
    _, records, summary = generated

    assert {"regular", "tax", "adjustment", "rounding_error"}.issubset(
        {record["cost_type"] for record in records}
    )

    credit_rows = [record for record in records if record["credits"]]
    assert credit_rows
    assert all(
        credit["amount"] < 0
        for record in credit_rows
        for credit in record["credits"]
    )

    assert summary["rows_with_multiple_credits"] > 0
    assert any(len(record["credits"]) > 1 for record in records)
    assert set(summary["commitment_profiles"]) == {
        "gcp-flex-balanced",
        "gcp-compute-under",
        "gcp-resource-over",
    }
    assert summary["modeled_unused_commitment_cost"] > 0


def test_gcp_data_quality_scenarios_are_traceable(
    generated: tuple[Path, list[dict], dict],
) -> None:
    _, records, summary = generated

    assert summary["missing_label_rows"] > 0
    assert summary["late_arriving_rows"] > 0
    assert summary["invalid_rows"] == 1
    assert summary["duplicated_source_record_ids"] == 2
    assert summary["injected_anomaly_rows"] == 3

    invalid = [
        record
        for record in records
        if record["data_quality_status"] == "INVALID_NEGATIVE_USAGE"
    ]
    assert len(invalid) == 1
    assert invalid[0]["usage"]["amount"] < 0

    source_ids = pd.Series(
        [record["source_record_id"] for record in records]
    ).value_counts()
    assert int((source_ids > 1).sum()) == 2


def test_gcp_labels_and_credits_require_safe_unnesting(
    generated: tuple[Path, list[dict], dict],
) -> None:
    _, records, summary = generated

    repeated_both = [
        record
        for record in records
        if len(record["labels"]) > 1 and len(record["credits"]) > 1
    ]

    assert repeated_both
    assert summary["nested_field_controls"]["labels_are_repeated"] is True
    assert summary["nested_field_controls"]["credits_are_repeated"] is True
    assert "avoid multiplying billing rows" in summary[
        "nested_field_controls"
    ]["cross_unnest_warning"]


def test_shared_business_patterns_are_visible(
    generated: tuple[Path, list[dict], dict],
) -> None:
    root, _, _ = generated
    activity = pd.read_csv(
        root / "business_activity" / "business_activity.csv"
    )
    activity["activity_date"] = pd.to_datetime(activity["activity_date"])

    nonprod = activity[activity["environment"] == "nonprod"].copy()
    nonprod["is_weekend"] = nonprod["activity_date"].dt.weekday >= 5

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


def test_gcp_generation_is_reproducible(
    generated: tuple[Path, list[dict], dict],
    tmp_path: Path,
) -> None:
    root, _, first_summary = generated
    first_file = (
        root
        / "synthetic_enterprise_usage"
        / "gcp"
        / "gcp_billing.jsonl"
    )
    second_dir = tmp_path / "gcp"
    second_summary = generate_gcp_billing(CONFIG_DIR, second_dir)

    assert _sha256(first_file) == _sha256(second_dir / "gcp_billing.jsonl")
    assert first_summary == second_summary


def test_gcp_control_totals_match_output(
    generated: tuple[Path, list[dict], dict],
) -> None:
    root, records, summary = generated
    summary_file = (
        root
        / "synthetic_enterprise_usage"
        / "gcp"
        / "gcp_generator_validation_summary.json"
    )
    saved_summary = json.loads(summary_file.read_text(encoding="utf-8"))

    total_cost = round(sum(record["cost"] for record in records), 6)
    total_credit = round(
        sum(
            credit["amount"]
            for record in records
            for credit in record["credits"]
        ),
        6,
    )

    assert len(records) == summary["row_count"]
    assert total_cost == summary["total_cost_before_credits"]
    assert total_credit == summary["total_credit_amount"]
    assert round(total_cost + total_credit, 6) == summary["total_net_cost"]
    assert saved_summary == summary

"""Tests for provider-level source validation and control totals."""

from __future__ import annotations

import json
from pathlib import Path

import pandas as pd
import pytest

from generator.aws_billing_generator import generate_aws_billing
from generator.gcp_billing_generator import generate_gcp_billing
from validation.aws_source import validate_aws_source
from validation.gcp_source import validate_gcp_source
from validation.run_source_validation import run_source_validation


ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "config"
AWS_DIR = ROOT / "data" / "synthetic_enterprise_usage" / "aws"
GCP_DIR = ROOT / "data" / "synthetic_enterprise_usage" / "gcp"
VALIDATION_DIR = ROOT / "data" / "source_validation"


@pytest.fixture(scope="module", autouse=True)
def generated_and_validated_sources() -> None:
    generate_aws_billing(CONFIG_DIR, AWS_DIR)
    generate_gcp_billing(CONFIG_DIR, GCP_DIR)
    run_source_validation(ROOT)


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def test_validation_outputs_are_provider_specific() -> None:
    expected = {
        "aws_source_validation.json",
        "gcp_source_validation.json",
        "aws_data_quality_exceptions.csv",
        "gcp_data_quality_exceptions.csv",
        "source_control_summary.csv",
        "source_validation_summary.json",
    }
    actual = {path.name for path in VALIDATION_DIR.iterdir() if path.is_file()}
    assert expected.issubset(actual)

    forbidden_billing_files = {
        "unified_billing.csv",
        "combined_billing.csv",
        "multi_cloud_billing.csv",
        "focus_billing.csv",
    }
    assert not any(
        any((ROOT / "data").rglob(name)) for name in forbidden_billing_files
    )


def test_provider_reports_pass_with_expected_exceptions() -> None:
    aws = read_json(VALIDATION_DIR / "aws_source_validation.json")
    gcp = read_json(VALIDATION_DIR / "gcp_source_validation.json")

    assert aws["overall_status"] == "PASS_WITH_EXPECTED_EXCEPTIONS"
    assert gcp["overall_status"] == "PASS_WITH_EXPECTED_EXCEPTIONS"
    assert not any(check["status"] == "FAIL" for check in aws["checks"])
    assert not any(check["status"] == "FAIL" for check in gcp["checks"])


def test_source_control_summary_has_one_row_per_provider() -> None:
    controls = pd.read_csv(VALIDATION_DIR / "source_control_summary.csv")

    assert len(controls) == 2
    assert set(controls["provider_name"]) == {"AWS", "GCP"}
    assert controls["provider_name"].is_unique
    assert (controls["row_count"] > 10000).all()


def test_expected_data_quality_exceptions_are_detected() -> None:
    aws = read_json(VALIDATION_DIR / "aws_source_validation.json")
    gcp = read_json(VALIDATION_DIR / "gcp_source_validation.json")

    assert aws["exception_counts"] == {
        "duplicate_record_rows": 4,
        "duplicated_record_ids": 2,
        "invalid_rows": 1,
        "late_arriving_rows": 187,
        "missing_tag_rows": 1489,
    }
    assert gcp["exception_counts"] == {
        "duplicate_record_rows": 4,
        "duplicated_record_ids": 2,
        "invalid_rows": 1,
        "late_arriving_rows": 176,
        "missing_label_rows": 1404,
    }


def test_exception_logs_are_traceable_to_source_records() -> None:
    aws_exceptions = pd.read_csv(
        VALIDATION_DIR / "aws_data_quality_exceptions.csv", dtype=str
    )
    gcp_exceptions = pd.read_csv(
        VALIDATION_DIR / "gcp_data_quality_exceptions.csv", dtype=str
    )

    required_columns = {
        "provider_name",
        "source_record_id",
        "issue_code",
        "severity",
        "usage_date",
        "billing_account_id",
        "account_or_project_id",
        "service_name",
        "details",
    }
    assert required_columns.issubset(aws_exceptions.columns)
    assert required_columns.issubset(gcp_exceptions.columns)
    assert aws_exceptions["source_record_id"].notna().all()
    assert gcp_exceptions["source_record_id"].notna().all()
    assert {
        "DUPLICATE_RECORD_ID",
        "MISSING_BUSINESS_TAGS",
        "INVALID_NEGATIVE_USAGE",
        "LATE_ARRIVING_RECORD",
    }.issubset(set(aws_exceptions["issue_code"]))
    assert {
        "DUPLICATE_RECORD_ID",
        "MISSING_BUSINESS_LABELS",
        "INVALID_NEGATIVE_USAGE",
        "LATE_ARRIVING_RECORD",
    }.issubset(set(gcp_exceptions["issue_code"]))


def test_all_cloud_amount_is_control_only_not_billing_union() -> None:
    summary = read_json(VALIDATION_DIR / "source_validation_summary.json")

    expected = round(
        summary["provider_net_cost_controls"]["AWS"]
        + summary["provider_net_cost_controls"]["GCP"],
        6,
    )
    assert summary["billing_rows_were_combined"] is False
    assert summary["all_cloud_net_cost_control"] == expected


def test_aws_tampering_breaks_financial_reconciliation(tmp_path: Path) -> None:
    source = pd.read_csv(AWS_DIR / "aws_billing.csv", dtype=str)
    source.loc[0, "line_item_unblended_cost"] = str(
        float(source.loc[0, "line_item_unblended_cost"]) + 1000
    )
    tampered_file = tmp_path / "aws_billing_tampered.csv"
    source.to_csv(tampered_file, index=False)

    report, _ = validate_aws_source(
        config_dir=CONFIG_DIR,
        source_file=tampered_file,
        generator_summary_file=AWS_DIR / "aws_generator_validation_summary.json",
    )

    failed_checks = {
        check["check_id"]
        for check in report["checks"]
        if check["status"] == "FAIL"
    }
    assert report["overall_status"] == "FAIL"
    assert "aws.billed_cost_reconciliation" in failed_checks


def test_gcp_positive_credit_is_rejected(tmp_path: Path) -> None:
    records = []
    with (GCP_DIR / "gcp_billing.jsonl").open("r", encoding="utf-8") as file:
        for line in file:
            records.append(json.loads(line))

    credit_record = next(record for record in records if record["credits"])
    credit_record["credits"][0]["amount"] = abs(
        credit_record["credits"][0]["amount"]
    )
    tampered_file = tmp_path / "gcp_billing_tampered.jsonl"
    with tampered_file.open("w", encoding="utf-8") as file:
        for record in records:
            file.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
            file.write("\n")

    report, _ = validate_gcp_source(
        config_dir=CONFIG_DIR,
        source_file=tampered_file,
        generator_summary_file=GCP_DIR / "gcp_generator_validation_summary.json",
    )

    failed_checks = {
        check["check_id"]
        for check in report["checks"]
        if check["status"] == "FAIL"
    }
    assert report["overall_status"] == "FAIL"
    assert "gcp.credit_sign" in failed_checks
    assert "gcp.credit_total_reconciliation" in failed_checks


def test_gcp_nested_arrays_remain_unflattened() -> None:
    report = read_json(VALIDATION_DIR / "gcp_source_validation.json")
    check = next(
        item for item in report["checks"]
        if item["check_id"] == "gcp.cross_unnest_risk"
    )

    assert check["status"] == "PASS"
    assert check["actual"]["rows_with_both_labels_and_credits"] > 0
    assert "separately" in check["actual"]["required_action"].lower()

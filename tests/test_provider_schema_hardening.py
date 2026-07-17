"""Tests for the provider schema hardening milestone."""

from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

AWS_PATH = Path("data/synthetic_enterprise_usage/aws/aws_billing.csv")
GCP_PATH = Path("data/synthetic_enterprise_usage/gcp/gcp_billing.jsonl")
SUMMARY_PATH = Path("data/schema_hardening/provider_schema_hardening_summary.json")


def _read_aws() -> list[dict[str, str]]:
    assert AWS_PATH.exists(), f"Run the AWS generator first: {AWS_PATH}"
    with AWS_PATH.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _read_gcp() -> list[dict]:
    assert GCP_PATH.exists(), f"Run the GCP generator first: {GCP_PATH}"
    with GCP_PATH.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def test_hardening_summary_passes_without_financial_changes() -> None:
    assert SUMMARY_PATH.exists(), (
        "Run: python -m generator.provider_schema_hardening"
    )
    summary = json.loads(SUMMARY_PATH.read_text(encoding="utf-8"))
    assert summary["overall_status"] == "PASS"
    assert summary["financial_values_changed"] is False
    assert summary["providers"]["AWS"]["row_count_variance"] == 0
    assert summary["providers"]["AWS"]["billed_cost_variance"] == 0
    assert summary["providers"]["GCP"]["row_count_variance"] == 0
    assert summary["providers"]["GCP"]["net_cost_variance"] == 0


def test_aws_native_billing_metadata_exists() -> None:
    rows = _read_aws()
    assert rows
    required = {
        "bill_bill_type",
        "bill_billing_entity",
        "bill_invoice_id",
        "bill_invoicing_entity",
        "x_payer_account_name",
    }
    assert required.issubset(rows[0])
    assert {row["bill_bill_type"] for row in rows} <= {
        "Anniversary",
        "Purchase",
        "Refund",
    }
    assert {row["bill_billing_entity"] for row in rows} <= {
        "AWS",
        "AWS Marketplace",
    }
    assert all(row["bill_invoice_id"] for row in rows)
    assert all(row["bill_invoicing_entity"] for row in rows)
    assert all(row["x_payer_account_name"] for row in rows)


def test_aws_account_name_is_explicit_extension() -> None:
    rows = _read_aws()
    assert "x_payer_account_name" in rows[0]
    assert "bill_payer_account_name" not in rows[0]


def test_gcp_system_labels_are_repeated_key_value_records() -> None:
    rows = _read_gcp()
    assert rows
    for row in rows:
        assert isinstance(row["system_labels"], list)
        for item in row["system_labels"]:
            assert set(item) == {"key", "value"}
            assert item["key"]
            assert item["value"]


def test_gcp_tags_are_repeated_records_with_full_shape() -> None:
    rows = _read_gcp()
    for row in rows:
        assert isinstance(row["tags"], list)
        for item in row["tags"]:
            assert set(item) == {"key", "value", "inherited", "namespace"}
            assert isinstance(item["inherited"], bool)
            assert item["key"]
            assert item["value"]
            assert item["namespace"]


def test_gcp_current_detailed_export_fields_exist() -> None:
    rows = _read_gcp()
    required = {
        "transaction_type",
        "seller_name",
        "subscription",
        "cost_at_effective_price_default",
        "cost_at_list_consumption_model",
    }
    assert required.issubset(rows[0])
    allowed_transactions = {None, "GOOGLE", "THIRD_PARTY_RESELLER", "THIRD_PARTY_AGENCY"}
    assert {row["transaction_type"] for row in rows} <= allowed_transactions
    for row in rows:
        subscription = row["subscription"]
        assert subscription is None or (
            isinstance(subscription, dict)
            and set(subscription) == {"instance_id"}
            and subscription["instance_id"]
        )
        assert isinstance(row["cost_at_effective_price_default"], (int, float))
        assert isinstance(row["cost_at_list_consumption_model"], (int, float))


def test_marketplace_seller_name_is_not_used_for_direct_google_rows() -> None:
    rows = _read_gcp()
    for row in rows:
        if row["seller_name"] is not None:
            assert row["transaction_type"] in {
                "THIRD_PARTY_RESELLER",
                "THIRD_PARTY_AGENCY",
            }


def test_price_struct_has_current_core_fields() -> None:
    rows = _read_gcp()
    required = {
        "list_price",
        "effective_price_default",
        "list_price_consumption_model",
        "effective_price",
        "tier_start_amount",
        "unit",
        "pricing_unit_quantity",
    }
    for row in rows:
        assert isinstance(row["price"], dict)
        assert required.issubset(row["price"])

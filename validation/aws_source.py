"""AWS CUR-style source validation controls."""

from __future__ import annotations

from decimal import Decimal
from pathlib import Path
from typing import Any

import pandas as pd

from validation.common import (
    _add_check,
    _decimal_sum,
    _exception_row,
    _money,
    _read_json,
    _read_yaml,
    _status,
    _within_tolerance,
)

def validate_aws_source(
    *,
    config_dir: Path,
    source_file: Path,
    generator_summary_file: Path,
) -> tuple[dict[str, Any], pd.DataFrame]:
    """Validate the AWS source-shaped CSV and return report plus exceptions."""
    rules = _read_yaml(config_dir / "source_validation_rules.yaml")
    generator_config = _read_yaml(config_dir / "generator_config.yaml")
    generator_summary = _read_json(generator_summary_file)
    aws_rules = rules["aws"]

    billing = pd.read_csv(source_file, dtype=str, keep_default_na=False)
    checks: list[Check] = []
    exceptions: list[dict[str, str]] = []

    required_columns = set(aws_rules["required_columns"])
    missing_columns = sorted(required_columns - set(billing.columns))
    _add_check(
        checks,
        check_id="aws.required_columns",
        status="PASS" if not missing_columns else "FAIL",
        expected="All required AWS source columns",
        actual=missing_columns,
        message="AWS source schema retains required CUR-style fields.",
    )

    if missing_columns:
        report = {
            "provider": "AWS",
            "source_file": str(source_file),
            "overall_status": "FAIL",
            "checks": checks,
            "control_totals": {},
            "exception_counts": {},
        }
        return report, pd.DataFrame(exceptions)

    numeric_columns = [
        "line_item_usage_amount",
        "pricing_public_on_demand_cost",
        "line_item_unblended_cost",
        "reservation_effective_cost",
        "reservation_unused_recurring_fee",
        "savings_plan_savings_plan_effective_cost",
        "savings_plan_unused_commitment",
    ]
    for column in numeric_columns:
        billing[column] = pd.to_numeric(billing[column], errors="coerce")

    usage_start = pd.to_datetime(
        billing["line_item_usage_start_date"], errors="coerce", utc=True
    )
    usage_end = pd.to_datetime(
        billing["line_item_usage_end_date"], errors="coerce", utc=True
    )
    available = pd.to_datetime(
        billing["record_available_date"], errors="coerce", utc=True
    )

    invalid_dates = int(
        usage_start.isna().sum() + usage_end.isna().sum() + available.isna().sum()
    )
    _add_check(
        checks,
        check_id="aws.parseable_dates",
        status="PASS" if invalid_dates == 0 else "FAIL",
        expected=0,
        actual=invalid_dates,
        message="AWS usage and availability dates must be parseable.",
    )

    date_start = usage_start.dt.date.min().isoformat()
    date_end = usage_start.dt.date.max().isoformat()
    distinct_dates = int(usage_start.dt.date.nunique())
    expected_start = rules["common"]["expected_date_start"]
    expected_end = rules["common"]["expected_date_end"]
    expected_dates = int(rules["common"]["expected_distinct_usage_dates"])

    _add_check(
        checks,
        check_id="aws.complete_date_range",
        status=(
            "PASS"
            if (date_start, date_end, distinct_dates)
            == (expected_start, expected_end, expected_dates)
            else "FAIL"
        ),
        expected={
            "start": expected_start,
            "end": expected_end,
            "distinct_dates": expected_dates,
        },
        actual={
            "start": date_start,
            "end": date_end,
            "distinct_dates": distinct_dates,
        },
        message="AWS source covers the complete configured period.",
    )

    accounts = pd.read_csv(config_dir / "aws_accounts.csv", dtype=str)
    expected_payers = set(accounts["payer_account_id"])
    expected_usage_accounts = set(accounts["usage_account_id"])
    actual_payers = set(billing["bill_payer_account_id"])
    actual_usage_accounts = set(billing["line_item_usage_account_id"])
    hierarchy_valid = (
        actual_payers == expected_payers
        and actual_usage_accounts.issubset(expected_usage_accounts)
        and actual_usage_accounts
    )
    _add_check(
        checks,
        check_id="aws.account_hierarchy",
        status="PASS" if hierarchy_valid else "FAIL",
        expected={
            "payer_account_ids": sorted(expected_payers),
            "allowed_usage_account_ids": sorted(expected_usage_accounts),
        },
        actual={
            "payer_account_ids": sorted(actual_payers),
            "usage_account_ids": sorted(actual_usage_accounts),
        },
        message="Payer and linked usage accounts remain separate.",
    )

    actual_types = set(billing["line_item_line_item_type"])
    allowed_types = set(aws_rules["allowed_line_item_types"])
    unexpected_types = sorted(actual_types - allowed_types)
    _add_check(
        checks,
        check_id="aws.allowed_line_item_types",
        status="PASS" if not unexpected_types else "FAIL",
        expected=sorted(allowed_types),
        actual=sorted(actual_types),
        message="AWS line-item types use the provider-native vocabulary.",
    )

    currency_valid = set(billing["line_item_currency_code"]) == {
        rules["common"]["billing_currency"]
    }
    _add_check(
        checks,
        check_id="aws.currency",
        status="PASS" if currency_valid else "FAIL",
        expected=rules["common"]["billing_currency"],
        actual=sorted(set(billing["line_item_currency_code"])),
        message="All AWS monetary rows use the configured currency.",
    )

    synthetic_values = set(billing["is_synthetic"].str.lower())
    _add_check(
        checks,
        check_id="aws.synthetic_flag",
        status="PASS" if synthetic_values == {"true"} else "FAIL",
        expected=["true"],
        actual=sorted(synthetic_values),
        message="Every generated AWS row is explicitly marked synthetic.",
    )

    duplicate_mask = billing.duplicated(
        subset=["line_item_line_item_id"], keep=False
    )
    duplicated_ids = int(
        billing.loc[duplicate_mask, "line_item_line_item_id"].nunique()
    )
    expected_duplicate_ids = int(
        generator_config["data_quality"]["duplicate_record_count"]["aws"]
    )
    _add_check(
        checks,
        check_id="aws.expected_duplicate_ids",
        status=(
            "EXPECTED_EXCEPTION"
            if duplicated_ids == expected_duplicate_ids
            else "FAIL"
        ),
        expected=expected_duplicate_ids,
        actual=duplicated_ids,
        message="Deliberate duplicate AWS source identifiers were detected.",
    )
    for _, row in billing.loc[duplicate_mask].iterrows():
        exceptions.append(
            _exception_row(
                provider_name="AWS",
                source_record_id=row["line_item_line_item_id"],
                issue_code="DUPLICATE_RECORD_ID",
                severity="ERROR",
                usage_date=str(row["line_item_usage_start_date"])[:10],
                billing_account_id=row["bill_payer_account_id"],
                account_or_project_id=row["line_item_usage_account_id"],
                service_name=row["line_item_product_code"],
                data_quality_status=row["data_quality_status"],
                injected_scenario=row["injected_scenario"],
                details="The same AWS line-item identifier appears more than once.",
            )
        )

    tag_columns = aws_rules["business_tag_columns"]
    missing_status_mask = billing["data_quality_status"] == "MISSING_TAGS"
    blank_tag_mask = billing[tag_columns].eq("").all(axis=1)
    missing_tag_count = int(missing_status_mask.sum())
    missing_tag_consistent = bool(blank_tag_mask.loc[missing_status_mask].all())
    _add_check(
        checks,
        check_id="aws.expected_missing_tags",
        status=(
            "EXPECTED_EXCEPTION"
            if missing_tag_count == int(generator_summary["missing_tag_rows"])
            and missing_tag_consistent
            else "FAIL"
        ),
        expected=int(generator_summary["missing_tag_rows"]),
        actual=missing_tag_count,
        message="Missing AWS billing tags remain visible and traceable.",
    )
    for _, row in billing.loc[missing_status_mask].iterrows():
        exceptions.append(
            _exception_row(
                provider_name="AWS",
                source_record_id=row["line_item_line_item_id"],
                issue_code="MISSING_BUSINESS_TAGS",
                severity="WARNING",
                usage_date=str(row["line_item_usage_start_date"])[:10],
                billing_account_id=row["bill_payer_account_id"],
                account_or_project_id=row["line_item_usage_account_id"],
                service_name=row["line_item_product_code"],
                data_quality_status=row["data_quality_status"],
                injected_scenario=row["injected_scenario"],
                details="Required application, department, environment, cost center, and owner tags are blank.",
            )
        )

    invalid_mask = billing["data_quality_status"] == "INVALID_NEGATIVE_USAGE"
    invalid_count = int(invalid_mask.sum())
    invalid_usage_consistent = bool(
        (billing.loc[invalid_mask, "line_item_usage_amount"] < 0).all()
    )
    expected_invalid = int(
        generator_config["data_quality"]["invalid_record_count"]["aws"]
    )
    _add_check(
        checks,
        check_id="aws.expected_invalid_usage",
        status=(
            "EXPECTED_EXCEPTION"
            if invalid_count == expected_invalid and invalid_usage_consistent
            else "FAIL"
        ),
        expected=expected_invalid,
        actual=invalid_count,
        message="Deliberate negative-usage records were detected, not removed.",
    )
    for _, row in billing.loc[invalid_mask].iterrows():
        exceptions.append(
            _exception_row(
                provider_name="AWS",
                source_record_id=row["line_item_line_item_id"],
                issue_code="INVALID_NEGATIVE_USAGE",
                severity="ERROR",
                usage_date=str(row["line_item_usage_start_date"])[:10],
                billing_account_id=row["bill_payer_account_id"],
                account_or_project_id=row["line_item_usage_account_id"],
                service_name=row["line_item_product_code"],
                data_quality_status=row["data_quality_status"],
                injected_scenario=row["injected_scenario"],
                details=f"Usage amount is {row['line_item_usage_amount']}.",
            )
        )

    late_mask = billing["is_late_arriving"].str.lower() == "true"
    arrival_lag_days = (available.dt.normalize() - usage_end.dt.normalize()).dt.days
    late_count = int(late_mask.sum())
    late_consistent = bool((arrival_lag_days.loc[late_mask] >= 4).all())
    _add_check(
        checks,
        check_id="aws.expected_late_arrivals",
        status=(
            "EXPECTED_EXCEPTION"
            if late_count == int(generator_summary["late_arriving_rows"])
            and late_consistent
            else "FAIL"
        ),
        expected=int(generator_summary["late_arriving_rows"]),
        actual=late_count,
        message="Late-arriving AWS billing records were detected and retained.",
    )
    for index, row in billing.loc[late_mask].iterrows():
        exceptions.append(
            _exception_row(
                provider_name="AWS",
                source_record_id=row["line_item_line_item_id"],
                issue_code="LATE_ARRIVING_RECORD",
                severity="WARNING",
                usage_date=str(row["line_item_usage_start_date"])[:10],
                billing_account_id=row["bill_payer_account_id"],
                account_or_project_id=row["line_item_usage_account_id"],
                service_name=row["line_item_product_code"],
                data_quality_status=row["data_quality_status"],
                injected_scenario=row["injected_scenario"],
                details=f"Record became available {int(arrival_lag_days.loc[index])} days after usage end.",
            )
        )

    negative_types = set(aws_rules["negative_cost_line_item_types"])
    negative_rows = billing["line_item_line_item_type"].isin(negative_types)
    negative_sign_valid = bool(
        (billing.loc[negative_rows, "line_item_unblended_cost"] < 0).all()
    )
    _add_check(
        checks,
        check_id="aws.credit_refund_sign",
        status="PASS" if negative_sign_valid else "FAIL",
        expected="Credit and Refund costs are negative",
        actual=billing.loc[
            negative_rows,
            ["line_item_line_item_type", "line_item_unblended_cost"],
        ].to_dict("records"),
        message="AWS credits and refunds remain separate negative-cost rows.",
    )

    actual_public_cost = _decimal_sum(billing["pricing_public_on_demand_cost"])
    expected_public_cost = Decimal(
        str(generator_summary["total_public_on_demand_cost"])
    )
    actual_billed_cost = _decimal_sum(billing["line_item_unblended_cost"])
    expected_billed_cost = Decimal(str(generator_summary["total_billed_cost"]))

    _add_check(
        checks,
        check_id="aws.generator_row_count_reconciliation",
        status=(
            "PASS"
            if len(billing) == int(generator_summary["row_count"])
            else "FAIL"
        ),
        expected=int(generator_summary["row_count"]),
        actual=len(billing),
        message="AWS source row count matches its generator control total.",
    )
    _add_check(
        checks,
        check_id="aws.public_cost_reconciliation",
        status=(
            "PASS"
            if _within_tolerance(actual_public_cost, expected_public_cost, rules)
            else "FAIL"
        ),
        expected=_money(expected_public_cost),
        actual=_money(actual_public_cost),
        message="AWS public on-demand cost matches the generator summary.",
    )
    _add_check(
        checks,
        check_id="aws.billed_cost_reconciliation",
        status=(
            "PASS"
            if _within_tolerance(actual_billed_cost, expected_billed_cost, rules)
            else "FAIL"
        ),
        expected=_money(expected_billed_cost),
        actual=_money(actual_billed_cost),
        message="AWS billed cost matches the generator summary.",
    )

    anomaly_count = int(
        billing["injected_scenario"].str.endswith("_spike", na=False).sum()
    )
    _add_check(
        checks,
        check_id="aws.injected_anomaly_traceability",
        status=(
            "PASS"
            if anomaly_count == int(generator_summary["injected_anomaly_rows"])
            else "FAIL"
        ),
        expected=int(generator_summary["injected_anomaly_rows"]),
        actual=anomaly_count,
        message="Injected AWS business anomalies remain traceable but are not treated as data-quality failures.",
    )

    exception_counts = {
        "duplicate_record_rows": int(duplicate_mask.sum()),
        "duplicated_record_ids": duplicated_ids,
        "missing_tag_rows": missing_tag_count,
        "invalid_rows": invalid_count,
        "late_arriving_rows": late_count,
    }
    report = {
        "provider": "AWS",
        "source_format": aws_rules["source_format"],
        "source_file": str(source_file),
        "overall_status": _status(checks, len(exceptions)),
        "checks": checks,
        "control_totals": {
            "row_count": len(billing),
            "public_on_demand_cost": _money(actual_public_cost),
            "billed_cost": _money(actual_billed_cost),
            "injected_anomaly_rows": anomaly_count,
        },
        "exception_counts": exception_counts,
    }
    return report, pd.DataFrame(exceptions)

"""GCP nested Billing Export source validation controls."""

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
    _read_jsonl,
    _read_yaml,
    _status,
    _within_tolerance,
)

def validate_gcp_source(
    *,
    config_dir: Path,
    source_file: Path,
    generator_summary_file: Path,
) -> tuple[dict[str, Any], pd.DataFrame]:
    """Validate nested GCP JSONL and return report plus exceptions."""
    rules = _read_yaml(config_dir / "source_validation_rules.yaml")
    generator_config = _read_yaml(config_dir / "generator_config.yaml")
    generator_summary = _read_json(generator_summary_file)
    gcp_rules = rules["gcp"]

    records = _read_jsonl(source_file)
    checks: list[Check] = []
    exceptions: list[dict[str, str]] = []

    required_fields = set(gcp_rules["required_top_level_fields"])
    records_with_missing_fields = [
        {
            "line_number": index,
            "missing_fields": sorted(required_fields - set(record)),
        }
        for index, record in enumerate(records, start=1)
        if required_fields - set(record)
    ]
    _add_check(
        checks,
        check_id="gcp.required_top_level_fields",
        status="PASS" if not records_with_missing_fields else "FAIL",
        expected="All required GCP source fields",
        actual=records_with_missing_fields[:10],
        message="GCP source retains required nested Billing Export fields.",
    )
    if records_with_missing_fields:
        report = {
            "provider": "GCP",
            "source_file": str(source_file),
            "overall_status": "FAIL",
            "checks": checks,
            "control_totals": {},
            "exception_counts": {},
        }
        return report, pd.DataFrame(exceptions)

    usage_dates = pd.to_datetime(
        [record["usage_start_time"] for record in records],
        errors="coerce",
        utc=True,
    )
    usage_ends = pd.to_datetime(
        [record["usage_end_time"] for record in records],
        errors="coerce",
        utc=True,
    )
    available_dates = pd.to_datetime(
        [record["record_available_date"] for record in records],
        errors="coerce",
        utc=True,
    )
    invalid_dates = int(
        usage_dates.isna().sum()
        + usage_ends.isna().sum()
        + available_dates.isna().sum()
    )
    _add_check(
        checks,
        check_id="gcp.parseable_dates",
        status="PASS" if invalid_dates == 0 else "FAIL",
        expected=0,
        actual=invalid_dates,
        message="GCP usage and availability dates must be parseable.",
    )

    date_start = usage_dates.date.min().isoformat()
    date_end = usage_dates.date.max().isoformat()
    distinct_dates = int(pd.Series(usage_dates.date).nunique())
    expected_start = rules["common"]["expected_date_start"]
    expected_end = rules["common"]["expected_date_end"]
    expected_dates = int(rules["common"]["expected_distinct_usage_dates"])
    _add_check(
        checks,
        check_id="gcp.complete_date_range",
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
        message="GCP source covers the complete configured period.",
    )

    projects = pd.read_csv(config_dir / "gcp_projects.csv", dtype=str)
    expected_billing_accounts = set(projects["billing_account_id"])
    expected_project_ids = set(projects["project_id"])
    actual_billing_accounts = {record["billing_account_id"] for record in records}
    actual_project_ids = {
        record["project"]["id"]
        for record in records
        if isinstance(record["project"], dict)
    }
    hierarchy_valid = (
        actual_billing_accounts == expected_billing_accounts
        and actual_project_ids.issubset(expected_project_ids)
        and actual_project_ids
    )
    _add_check(
        checks,
        check_id="gcp.billing_account_project_hierarchy",
        status="PASS" if hierarchy_valid else "FAIL",
        expected={
            "billing_account_ids": sorted(expected_billing_accounts),
            "allowed_project_ids": sorted(expected_project_ids),
        },
        actual={
            "billing_account_ids": sorted(actual_billing_accounts),
            "project_ids": sorted(actual_project_ids),
        },
        message="GCP billing accounts and projects remain separate hierarchy levels.",
    )

    nested_shape_valid = all(
        isinstance(record["service"], dict)
        and isinstance(record["sku"], dict)
        and isinstance(record["usage"], dict)
        and isinstance(record["labels"], list)
        and isinstance(record["credits"], list)
        for record in records
    )
    _add_check(
        checks,
        check_id="gcp.nested_source_shape",
        status="PASS" if nested_shape_valid else "FAIL",
        expected="Nested structs with repeated labels and credits",
        actual="Valid" if nested_shape_valid else "One or more malformed records",
        message="GCP nested and repeated structures remain unflattened.",
    )

    actual_cost_types = {record["cost_type"] for record in records}
    allowed_cost_types = set(gcp_rules["allowed_cost_types"])
    unexpected_cost_types = sorted(actual_cost_types - allowed_cost_types)
    _add_check(
        checks,
        check_id="gcp.allowed_cost_types",
        status="PASS" if not unexpected_cost_types else "FAIL",
        expected=sorted(allowed_cost_types),
        actual=sorted(actual_cost_types),
        message="GCP cost_type remains separate from nested credit classification.",
    )

    currency_values = {record["currency"] for record in records}
    _add_check(
        checks,
        check_id="gcp.currency",
        status=(
            "PASS"
            if currency_values == {rules["common"]["billing_currency"]}
            else "FAIL"
        ),
        expected=rules["common"]["billing_currency"],
        actual=sorted(currency_values),
        message="All GCP monetary records use the configured currency.",
    )

    synthetic_values = {bool(record["is_synthetic"]) for record in records}
    _add_check(
        checks,
        check_id="gcp.synthetic_flag",
        status="PASS" if synthetic_values == {True} else "FAIL",
        expected=[True],
        actual=sorted(synthetic_values),
        message="Every generated GCP row is explicitly marked synthetic.",
    )

    record_ids = pd.Series([record["source_record_id"] for record in records])
    duplicate_ids = set(record_ids[record_ids.duplicated(keep=False)])
    duplicate_mask = record_ids.isin(duplicate_ids)
    duplicated_id_count = len(duplicate_ids)
    expected_duplicate_ids = int(
        generator_config["data_quality"]["duplicate_record_count"]["gcp"]
    )
    _add_check(
        checks,
        check_id="gcp.expected_duplicate_ids",
        status=(
            "EXPECTED_EXCEPTION"
            if duplicated_id_count == expected_duplicate_ids
            else "FAIL"
        ),
        expected=expected_duplicate_ids,
        actual=duplicated_id_count,
        message="Deliberate duplicate GCP source identifiers were detected.",
    )

    missing_label_count = 0
    invalid_count = 0
    late_count = 0
    credit_sign_valid = True
    rows_with_multiple_credits = 0
    anomaly_count = 0
    potential_cross_unnest_rows = 0

    required_label_keys = set(gcp_rules["required_label_keys"])
    for index, record in enumerate(records):
        project_id = (
            record["project"]["id"]
            if isinstance(record["project"], dict)
            else ""
        )
        service_name = record["service"].get("description", "")
        usage_date = str(record["usage_start_time"])[:10]

        if bool(duplicate_mask.iloc[index]):
            exceptions.append(
                _exception_row(
                    provider_name="GCP",
                    source_record_id=record["source_record_id"],
                    issue_code="DUPLICATE_RECORD_ID",
                    severity="ERROR",
                    usage_date=usage_date,
                    billing_account_id=record["billing_account_id"],
                    account_or_project_id=project_id,
                    service_name=service_name,
                    data_quality_status=record["data_quality_status"],
                    injected_scenario=record["injected_scenario"],
                    details="The same GCP source_record_id appears more than once.",
                )
            )

        if record["data_quality_status"] == "MISSING_LABELS":
            missing_label_count += 1
            labels_empty = record["labels"] == []
            if not labels_empty:
                credit_sign_valid = False
            exceptions.append(
                _exception_row(
                    provider_name="GCP",
                    source_record_id=record["source_record_id"],
                    issue_code="MISSING_BUSINESS_LABELS",
                    severity="WARNING",
                    usage_date=usage_date,
                    billing_account_id=record["billing_account_id"],
                    account_or_project_id=project_id,
                    service_name=service_name,
                    data_quality_status=record["data_quality_status"],
                    injected_scenario=record["injected_scenario"],
                    details="Required application, department, environment, cost center, and owner labels are absent.",
                )
            )

        if record["data_quality_status"] == "INVALID_NEGATIVE_USAGE":
            invalid_count += 1
            exceptions.append(
                _exception_row(
                    provider_name="GCP",
                    source_record_id=record["source_record_id"],
                    issue_code="INVALID_NEGATIVE_USAGE",
                    severity="ERROR",
                    usage_date=usage_date,
                    billing_account_id=record["billing_account_id"],
                    account_or_project_id=project_id,
                    service_name=service_name,
                    data_quality_status=record["data_quality_status"],
                    injected_scenario=record["injected_scenario"],
                    details=f"Usage amount is {record['usage']['amount']}.",
                )
            )

        if bool(record["is_late_arriving"]):
            late_count += 1
            lag_days = int(
                (
                    available_dates[index].normalize()
                    - usage_ends[index].normalize()
                ).days
            )
            exceptions.append(
                _exception_row(
                    provider_name="GCP",
                    source_record_id=record["source_record_id"],
                    issue_code="LATE_ARRIVING_RECORD",
                    severity="WARNING",
                    usage_date=usage_date,
                    billing_account_id=record["billing_account_id"],
                    account_or_project_id=project_id,
                    service_name=service_name,
                    data_quality_status=record["data_quality_status"],
                    injected_scenario=record["injected_scenario"],
                    details=f"Record became available {lag_days} days after usage end.",
                )
            )

        credits = record["credits"]
        if any(Decimal(str(credit["amount"])) > 0 for credit in credits):
            credit_sign_valid = False
        if len(credits) > 1:
            rows_with_multiple_credits += 1
        if record["labels"] and credits:
            potential_cross_unnest_rows += 1

        if str(record["injected_scenario"]).endswith("_spike"):
            anomaly_count += 1

        if record["data_quality_status"] == "VALID" and record["project"]:
            label_keys = {label["key"] for label in record["labels"]}
            if not required_label_keys.issubset(label_keys):
                _add_check(
                    checks,
                    check_id=f"gcp.required_label_keys.{record['source_record_id']}",
                    status="FAIL",
                    expected=sorted(required_label_keys),
                    actual=sorted(label_keys),
                    message="A valid GCP usage record is missing required label keys.",
                )
                break

    expected_missing_labels = int(generator_summary["missing_label_rows"])
    _add_check(
        checks,
        check_id="gcp.expected_missing_labels",
        status=(
            "EXPECTED_EXCEPTION"
            if missing_label_count == expected_missing_labels
            else "FAIL"
        ),
        expected=expected_missing_labels,
        actual=missing_label_count,
        message="Missing GCP billing labels remain visible and traceable.",
    )

    expected_invalid = int(
        generator_config["data_quality"]["invalid_record_count"]["gcp"]
    )
    invalid_usage_consistent = all(
        Decimal(str(record["usage"]["amount"])) < 0
        for record in records
        if record["data_quality_status"] == "INVALID_NEGATIVE_USAGE"
    )
    _add_check(
        checks,
        check_id="gcp.expected_invalid_usage",
        status=(
            "EXPECTED_EXCEPTION"
            if invalid_count == expected_invalid and invalid_usage_consistent
            else "FAIL"
        ),
        expected=expected_invalid,
        actual=invalid_count,
        message="Deliberate negative-usage GCP records were detected, not removed.",
    )

    late_consistent = all(
        (available_dates[index].normalize() - usage_ends[index].normalize()).days
        >= 4
        for index, record in enumerate(records)
        if bool(record["is_late_arriving"])
    )
    _add_check(
        checks,
        check_id="gcp.expected_late_arrivals",
        status=(
            "EXPECTED_EXCEPTION"
            if late_count == int(generator_summary["late_arriving_rows"])
            and late_consistent
            else "FAIL"
        ),
        expected=int(generator_summary["late_arriving_rows"]),
        actual=late_count,
        message="Late-arriving GCP billing records were detected and retained.",
    )

    _add_check(
        checks,
        check_id="gcp.credit_sign",
        status="PASS" if credit_sign_valid else "FAIL",
        expected="Every nested credit amount is zero or negative",
        actual="Valid" if credit_sign_valid else "Positive or malformed credit detected",
        message="Nested GCP credits reduce cost rather than increase it.",
    )
    _add_check(
        checks,
        check_id="gcp.multiple_credit_rows",
        status=(
            "PASS"
            if rows_with_multiple_credits
            == int(generator_summary["rows_with_multiple_credits"])
            else "FAIL"
        ),
        expected=int(generator_summary["rows_with_multiple_credits"]),
        actual=rows_with_multiple_credits,
        message="Rows carrying stacked GCP credits remain traceable.",
    )
    _add_check(
        checks,
        check_id="gcp.cross_unnest_risk",
        status="PASS",
        expected="Labels and credits remain separate repeated arrays",
        actual={
            "rows_with_both_labels_and_credits": potential_cross_unnest_rows,
            "required_action": "Unnest or aggregate labels and credits separately during FOCUS staging.",
        },
        message="Potential row multiplication is documented before SQL normalization.",
    )

    actual_cost = _decimal_sum(record["cost"] for record in records)
    actual_credit = _decimal_sum(
        credit["amount"]
        for record in records
        for credit in record["credits"]
    )
    actual_net = actual_cost + actual_credit
    expected_cost = Decimal(str(generator_summary["total_cost_before_credits"]))
    expected_credit = Decimal(str(generator_summary["total_credit_amount"]))
    expected_net = Decimal(str(generator_summary["total_net_cost"]))

    _add_check(
        checks,
        check_id="gcp.generator_row_count_reconciliation",
        status=(
            "PASS"
            if len(records) == int(generator_summary["row_count"])
            else "FAIL"
        ),
        expected=int(generator_summary["row_count"]),
        actual=len(records),
        message="GCP source row count matches its generator control total.",
    )
    for check_id, actual, expected, message in [
        (
            "gcp.cost_before_credits_reconciliation",
            actual_cost,
            expected_cost,
            "GCP cost before credits matches the generator summary.",
        ),
        (
            "gcp.credit_total_reconciliation",
            actual_credit,
            expected_credit,
            "Nested GCP credits match the generator summary.",
        ),
        (
            "gcp.net_cost_reconciliation",
            actual_net,
            expected_net,
            "GCP net cost equals cost plus nested credits.",
        ),
    ]:
        _add_check(
            checks,
            check_id=check_id,
            status=(
                "PASS" if _within_tolerance(actual, expected, rules) else "FAIL"
            ),
            expected=_money(expected),
            actual=_money(actual),
            message=message,
        )

    _add_check(
        checks,
        check_id="gcp.injected_anomaly_traceability",
        status=(
            "PASS"
            if anomaly_count == int(generator_summary["injected_anomaly_rows"])
            else "FAIL"
        ),
        expected=int(generator_summary["injected_anomaly_rows"]),
        actual=anomaly_count,
        message="Injected GCP business anomalies remain traceable but are not treated as data-quality failures.",
    )

    exception_counts = {
        "duplicate_record_rows": int(duplicate_mask.sum()),
        "duplicated_record_ids": duplicated_id_count,
        "missing_label_rows": missing_label_count,
        "invalid_rows": invalid_count,
        "late_arriving_rows": late_count,
    }
    report = {
        "provider": "GCP",
        "source_format": gcp_rules["source_format"],
        "source_file": str(source_file),
        "overall_status": _status(checks, len(exceptions)),
        "checks": checks,
        "control_totals": {
            "row_count": len(records),
            "cost_before_credits": _money(actual_cost),
            "credit_amount": _money(actual_credit),
            "net_cost": _money(actual_net),
            "rows_with_multiple_credits": rows_with_multiple_credits,
            "injected_anomaly_rows": anomaly_count,
        },
        "exception_counts": exception_counts,
    }
    return report, pd.DataFrame(exceptions)

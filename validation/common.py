"""Shared helpers for provider-specific source validation."""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable

import pandas as pd
import yaml


Check = dict[str, Any]

def _read_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return yaml.safe_load(file)


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as file:
        for line_number, line in enumerate(file, start=1):
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"Invalid JSON on line {line_number} of {path}"
                ) from exc
    return records


def _decimal_sum(values: Iterable[object]) -> Decimal:
    total = Decimal("0")
    for value in values:
        if value is None or value == "":
            continue
        total += Decimal(str(value))
    return total


def _money(value: Decimal) -> float:
    return round(float(value), 6)


def _tolerance(control_total: Decimal, rules: dict[str, Any]) -> Decimal:
    settings = rules["common"]["reconciliation_tolerance"]
    absolute = Decimal(str(settings["absolute"]))
    relative = abs(control_total) * Decimal(str(settings["relative"]))
    return max(absolute, relative)


def _within_tolerance(
    actual: Decimal,
    expected: Decimal,
    rules: dict[str, Any],
) -> bool:
    return abs(actual - expected) <= _tolerance(expected, rules)


def _add_check(
    checks: list[Check],
    *,
    check_id: str,
    status: str,
    expected: object,
    actual: object,
    message: str,
) -> None:
    checks.append(
        {
            "check_id": check_id,
            "status": status,
            "expected": expected,
            "actual": actual,
            "message": message,
        }
    )


def _status(checks: list[Check], exception_count: int) -> str:
    if any(check["status"] == "FAIL" for check in checks):
        return "FAIL"
    if exception_count:
        return "PASS_WITH_EXPECTED_EXCEPTIONS"
    return "PASS"


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(payload, file, indent=2, sort_keys=True)
        file.write("\n")


def _exception_row(
    *,
    provider_name: str,
    source_record_id: str,
    issue_code: str,
    severity: str,
    usage_date: str,
    billing_account_id: str,
    account_or_project_id: str,
    service_name: str,
    data_quality_status: str,
    injected_scenario: str,
    details: str,
) -> dict[str, str]:
    return {
        "provider_name": provider_name,
        "source_record_id": source_record_id,
        "issue_code": issue_code,
        "severity": severity,
        "usage_date": usage_date,
        "billing_account_id": billing_account_id,
        "account_or_project_id": account_or_project_id,
        "service_name": service_name,
        "data_quality_status": data_quality_status,
        "injected_scenario": injected_scenario,
        "details": details,
    }

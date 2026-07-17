"""Harden synthetic AWS and GCP billing outputs to realistic provider-native subsets.

This module does not change row counts, billed costs, credits, anomalies, duplicate
records, invalid records, or commitment behavior. It adds or corrects source
metadata and nested structures so downstream BigQuery raw/staging work uses a
more realistic provider schema.

Run from the repository root:
    python -m generator.provider_schema_hardening
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable

AWS_DEFAULT_PATH = Path("data/synthetic_enterprise_usage/aws/aws_billing.csv")
GCP_DEFAULT_PATH = Path("data/synthetic_enterprise_usage/gcp/gcp_billing.jsonl")
SUMMARY_DEFAULT_PATH = Path(
    "data/schema_hardening/provider_schema_hardening_summary.json"
)

AWS_NATIVE_ADDITIONS = [
    "bill_bill_type",
    "bill_billing_entity",
    "bill_invoice_id",
    "bill_invoicing_entity",
]
AWS_EXTENSION_ADDITIONS = ["x_payer_account_name"]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _first_value(mapping: dict[str, Any], candidates: Iterable[str]) -> Any:
    for key in candidates:
        if key in mapping and mapping[key] not in (None, ""):
            return mapping[key]
    return None


def _text_blob(mapping: dict[str, Any], candidates: Iterable[str]) -> str:
    values = []
    for key in candidates:
        value = mapping.get(key)
        if value not in (None, ""):
            if isinstance(value, (dict, list)):
                values.append(json.dumps(value, sort_keys=True))
            else:
                values.append(str(value))
    return " ".join(values).lower()


def _to_decimal(value: Any, default: Decimal = Decimal("0")) -> Decimal:
    if value in (None, ""):
        return default
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return default


def _decimal_json(value: Decimal) -> float:
    return float(value.quantize(Decimal("0.000001")))


def _billing_month(row: dict[str, Any]) -> str:
    value = _first_value(
        row,
        [
            "bill_billing_period_start_date",
            "bill/BillingPeriodStartDate",
            "billing_period_start",
            "line_item_usage_start_date",
            "lineItem/UsageStartDate",
        ],
    )
    if value is None:
        return "UNKNOWN"
    text = str(value)
    digits = "".join(ch for ch in text[:10] if ch.isdigit())
    return digits[:6] if len(digits) >= 6 else "UNKNOWN"


def _aws_marketplace(row: dict[str, Any]) -> bool:
    blob = _text_blob(
        row,
        [
            "bill_billing_entity",
            "product_product_name",
            "product_product_family",
            "product_servicecode",
            "product_product_code",
            "pricing_purchase_option",
            "pricing_term",
            "line_item_line_item_description",
            "line_item_legal_entity",
        ],
    )
    return "marketplace" in blob or "third party" in blob or "third-party" in blob


def _aws_bill_type(row: dict[str, Any]) -> str:
    line_type = str(
        _first_value(
            row,
            ["line_item_line_item_type", "lineItem/LineItemType", "line_item_type"],
        )
        or ""
    ).lower()
    purchase_blob = _text_blob(
        row,
        [
            "pricing_purchase_option",
            "pricing_term",
            "line_item_line_item_description",
        ],
    )

    if "refund" in line_type:
        return "Refund"
    if "upfront" in line_type or "upfront" in purchase_blob:
        return "Purchase"
    return "Anniversary"


def _aws_billed_cost_total(rows: list[dict[str, Any]]) -> Decimal:
    candidates = [
        "line_item_unblended_cost",
        "line_item_net_unblended_cost",
        "billed_cost",
        "lineItem/UnblendedCost",
    ]
    return sum(
        (_to_decimal(_first_value(row, candidates)) for row in rows), Decimal("0")
    )


def harden_aws_csv(
    path: Path,
    *,
    payer_account_name: str = "Retail Co Management Account",
    invoicing_entity: str = "Amazon Web Services, Inc.",
) -> dict[str, Any]:
    """Add realistic AWS CUR-style billing metadata without changing costs."""
    if not path.exists():
        raise FileNotFoundError(f"AWS source file not found: {path}")

    before_hash = _sha256(path)
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"AWS CSV has no header: {path}")
        original_fields = list(reader.fieldnames)
        rows = list(reader)

    row_count_before = len(rows)
    cost_before = _aws_billed_cost_total(rows)

    for row in rows:
        marketplace = _aws_marketplace(row)
        billing_entity = "AWS Marketplace" if marketplace else "AWS"
        bill_type = _aws_bill_type(row)
        payer_id = str(
            _first_value(
                row,
                ["bill_payer_account_id", "bill/PayerAccountId", "payer_account_id"],
            )
            or "UNKNOWN"
        )
        invoice_suffix = "MKT" if marketplace else "AWS"
        month = _billing_month(row)

        row["bill_bill_type"] = bill_type
        row["bill_billing_entity"] = billing_entity
        row["bill_invoice_id"] = f"INV-{month}-{payer_id[-4:]}-{invoice_suffix}"
        row["bill_invoicing_entity"] = invoicing_entity
        # AWS documents bill/PayerAccountId, not bill/PayerAccountName. Keep the
        # friendly name as an explicit project extension instead of pretending
        # it is a native CUR column.
        row["x_payer_account_name"] = payer_account_name

    fieldnames = original_fields + [
        name
        for name in AWS_NATIVE_ADDITIONS + AWS_EXTENSION_ADDITIONS
        if name not in original_fields
    ]

    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        after_rows = list(csv.DictReader(handle))
    row_count_after = len(after_rows)
    cost_after = _aws_billed_cost_total(after_rows)

    return {
        "provider": "AWS",
        "source_file": str(path),
        "row_count_before": row_count_before,
        "row_count_after": row_count_after,
        "row_count_variance": row_count_after - row_count_before,
        "billed_cost_before": float(cost_before),
        "billed_cost_after": float(cost_after),
        "billed_cost_variance": float(cost_after - cost_before),
        "sha256_before": before_hash,
        "sha256_after": _sha256(path),
        "native_fields_added": AWS_NATIVE_ADDITIONS,
        "extension_fields_added": AWS_EXTENSION_ADDITIONS,
        "status": "PASS"
        if row_count_before == row_count_after and cost_before == cost_after
        else "FAIL",
    }


def _parse_key_value(value: str, default_key: str) -> tuple[str, str]:
    for delimiter in ("=", ":"):
        if delimiter in value:
            key, parsed_value = value.split(delimiter, 1)
            if key.strip() and parsed_value.strip():
                return key.strip(), parsed_value.strip()
    return default_key, value.strip()


def _normalize_system_labels(value: Any, row: dict[str, Any]) -> list[dict[str, str]]:
    if value in (None, ""):
        return []
    items = value if isinstance(value, list) else [value]
    normalized: list[dict[str, str]] = []
    service_blob = _text_blob(row, ["service", "sku", "resource"])
    default_key = (
        "compute.googleapis.com/machine_spec"
        if "compute" in service_blob
        else "retail.example/system_label"
    )

    for item in items:
        if isinstance(item, dict):
            key = item.get("key")
            parsed_value = item.get("value")
        else:
            key, parsed_value = _parse_key_value(str(item), default_key)
        if key not in (None, "") and parsed_value not in (None, ""):
            normalized.append({"key": str(key), "value": str(parsed_value)})
    return normalized


def _normalize_tags(value: Any) -> list[dict[str, Any]]:
    if value in (None, ""):
        return []
    items = value if isinstance(value, list) else [value]
    normalized: list[dict[str, Any]] = []
    for item in items:
        if isinstance(item, dict):
            key = item.get("key")
            parsed_value = item.get("value")
            inherited = bool(item.get("inherited", False))
            namespace = item.get("namespace") or "retail-co"
        else:
            key, parsed_value = _parse_key_value(str(item), "synthetic_tag")
            inherited = False
            namespace = "retail-co"
        if key not in (None, "") and parsed_value not in (None, ""):
            normalized.append(
                {
                    "key": str(key),
                    "value": str(parsed_value),
                    "inherited": inherited,
                    "namespace": str(namespace),
                }
            )
    return normalized


def _gcp_marketplace(row: dict[str, Any]) -> bool:
    blob = _text_blob(
        row,
        [
            "service",
            "sku",
            "invoice",
            "seller_name",
            "transaction_type",
            "injected_scenario",
        ],
    )
    return "marketplace" in blob or "third party" in blob or "third-party" in blob


def _usage_amount_and_unit(row: dict[str, Any]) -> tuple[Decimal, str | None]:
    usage = row.get("usage")
    if not isinstance(usage, dict):
        return Decimal("0"), None
    amount = _to_decimal(
        usage.get("amount_in_pricing_units", usage.get("amount", Decimal("0")))
    )
    unit = usage.get("pricing_unit") or usage.get("unit")
    return amount, str(unit) if unit not in (None, "") else None


def _ensure_price_fields(row: dict[str, Any]) -> dict[str, Any]:
    price = row.get("price")
    if not isinstance(price, dict):
        price = {}

    usage_amount, usage_unit = _usage_amount_and_unit(row)
    quantity = _to_decimal(price.get("pricing_unit_quantity"), Decimal("1"))
    if quantity == 0:
        quantity = Decimal("1")

    cost = _to_decimal(row.get("cost"))
    cost_at_list = _to_decimal(row.get("cost_at_list"), cost)

    inferred_list_price = (
        cost_at_list * quantity / usage_amount if usage_amount != 0 else Decimal("0")
    )
    inferred_effective_price = (
        cost * quantity / usage_amount if usage_amount != 0 else Decimal("0")
    )

    list_price = _to_decimal(price.get("list_price"), inferred_list_price)
    effective_default = _to_decimal(
        price.get("effective_price_default"), inferred_effective_price
    )
    list_consumption = _to_decimal(
        price.get("list_price_consumption_model"), list_price
    )
    effective_price = _to_decimal(price.get("effective_price"), inferred_effective_price)

    price["list_price"] = _decimal_json(list_price)
    price["effective_price_default"] = _decimal_json(effective_default)
    price["list_price_consumption_model"] = _decimal_json(list_consumption)
    price["effective_price"] = _decimal_json(effective_price)
    price["tier_start_amount"] = _decimal_json(
        _to_decimal(price.get("tier_start_amount"), Decimal("0"))
    )
    price["unit"] = price.get("unit") or usage_unit
    price["pricing_unit_quantity"] = _decimal_json(quantity)
    return price


def _cost_from_price(
    row: dict[str, Any], price_field: str, fallback: Decimal
) -> Decimal:
    price = row.get("price")
    if not isinstance(price, dict):
        return fallback
    usage_amount, _ = _usage_amount_and_unit(row)
    quantity = _to_decimal(price.get("pricing_unit_quantity"), Decimal("1"))
    if quantity == 0 or usage_amount == 0:
        return fallback
    unit_price = _to_decimal(price.get(price_field), Decimal("0"))
    if unit_price == 0:
        return fallback
    return usage_amount * unit_price / quantity


def _gcp_net_cost_total(rows: list[dict[str, Any]]) -> Decimal:
    total = Decimal("0")
    for row in rows:
        total += _to_decimal(row.get("cost"))
        credits = row.get("credits")
        if isinstance(credits, list):
            for credit in credits:
                if isinstance(credit, dict):
                    total += _to_decimal(credit.get("amount"))
    return total


def harden_gcp_jsonl(path: Path) -> dict[str, Any]:
    """Correct GCP nested structures and add current detailed-export fields."""
    if not path.exists():
        raise FileNotFoundError(f"GCP source file not found: {path}")

    before_hash = _sha256(path)
    with path.open("r", encoding="utf-8") as handle:
        rows = [json.loads(line) for line in handle if line.strip()]

    row_count_before = len(rows)
    net_cost_before = _gcp_net_cost_total(rows)

    for row in rows:
        row["system_labels"] = _normalize_system_labels(
            row.get("system_labels"), row
        )
        row["tags"] = _normalize_tags(row.get("tags"))
        row["price"] = _ensure_price_fields(row)

        marketplace = _gcp_marketplace(row)
        cost_type = str(row.get("cost_type") or "").lower()
        if cost_type == "regular":
            row["transaction_type"] = (
                "THIRD_PARTY_RESELLER" if marketplace else "GOOGLE"
            )
        else:
            row["transaction_type"] = None
        row["seller_name"] = (
            "Retail Marketplace Vendor, Inc." if marketplace else None
        )

        profile_id = row.get("modeled_commitment_profile_id")
        consumption_model = row.get("consumption_model")
        if not profile_id and isinstance(consumption_model, dict):
            description = str(consumption_model.get("description") or "").lower()
            if "commit" in description or "cud" in description:
                profile_id = consumption_model.get("id")
        row["subscription"] = (
            {"instance_id": str(profile_id)} if profile_id not in (None, "") else None
        )

        cost = _to_decimal(row.get("cost"))
        cost_at_list = _to_decimal(row.get("cost_at_list"), cost)
        row["cost_at_effective_price_default"] = _decimal_json(
            _cost_from_price(row, "effective_price_default", cost)
        )
        row["cost_at_list_consumption_model"] = _decimal_json(
            _cost_from_price(row, "list_price_consumption_model", cost_at_list)
        )

    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")))
            handle.write("\n")
    temporary.replace(path)

    with path.open("r", encoding="utf-8") as handle:
        after_rows = [json.loads(line) for line in handle if line.strip()]
    row_count_after = len(after_rows)
    net_cost_after = _gcp_net_cost_total(after_rows)

    return {
        "provider": "GCP",
        "source_file": str(path),
        "row_count_before": row_count_before,
        "row_count_after": row_count_after,
        "row_count_variance": row_count_after - row_count_before,
        "net_cost_before": float(net_cost_before),
        "net_cost_after": float(net_cost_after),
        "net_cost_variance": float(net_cost_after - net_cost_before),
        "sha256_before": before_hash,
        "sha256_after": _sha256(path),
        "nested_fields_corrected": ["system_labels", "tags"],
        "fields_added": [
            "transaction_type",
            "seller_name",
            "subscription",
            "cost_at_effective_price_default",
            "cost_at_list_consumption_model",
        ],
        "status": "PASS"
        if row_count_before == row_count_after and net_cost_before == net_cost_after
        else "FAIL",
    }


def run_hardening(
    aws_path: Path = AWS_DEFAULT_PATH,
    gcp_path: Path = GCP_DEFAULT_PATH,
    summary_path: Path = SUMMARY_DEFAULT_PATH,
) -> dict[str, Any]:
    aws_result = harden_aws_csv(aws_path)
    gcp_result = harden_gcp_jsonl(gcp_path)
    overall_status = (
        "PASS"
        if aws_result["status"] == "PASS" and gcp_result["status"] == "PASS"
        else "FAIL"
    )
    summary = {
        "schema_reference_date": "2026-07-15",
        "generated_at_utc": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "overall_status": overall_status,
        "financial_values_changed": False if overall_status == "PASS" else True,
        "providers": {"AWS": aws_result, "GCP": gcp_result},
    }
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aws-path", type=Path, default=AWS_DEFAULT_PATH)
    parser.add_argument("--gcp-path", type=Path, default=GCP_DEFAULT_PATH)
    parser.add_argument("--summary-path", type=Path, default=SUMMARY_DEFAULT_PATH)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    summary = run_hardening(args.aws_path, args.gcp_path, args.summary_path)
    print(json.dumps(summary, indent=2))
    if summary["overall_status"] != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()

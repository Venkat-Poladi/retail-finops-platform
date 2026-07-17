"""Generate deterministic GCP Billing Export-style synthetic data.

The output is newline-delimited JSON so nested/repeated structures such as
project, usage, labels, credits, price, invoice, and adjustment_info remain
nested instead of being flattened prematurely.
"""

from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from pathlib import Path
from typing import Any
from uuid import NAMESPACE_URL, uuid5

import numpy as np
import pandas as pd
import yaml

from generator.business_activity import generate_business_activity


ANOMALY_FACTORS = {
    ("2026-02-19", "shared-platform-prod", "NetworkServices"): 3.9,
    ("2026-04-08", "analytics-prod", "CloudLogging"): 4.4,
    ("2026-05-18", "recommendations-prod", "VertexAI"): 5.2,
}


def _read_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return yaml.safe_load(file)


def _read_csv(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, dtype=str)


def _money(value: float) -> float:
    return round(float(value), 6)


def _record_id(*parts: object) -> str:
    key = "|".join(str(part) for part in parts)
    return str(uuid5(NAMESPACE_URL, key))


def _stable_number(value: str, digits: int = 12) -> str:
    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()
    number = int(digest[:15], 16) % (10**digits)
    return f"{number:0{digits}d}"


def _resource_name(prefix: str, workload_id: str) -> str:
    suffix = hashlib.sha1(
        f"{prefix}|{workload_id}".encode("utf-8")
    ).hexdigest()[:12]
    return f"{prefix}-{suffix}"


def _label_array(workload: pd.Series) -> list[dict[str, str]]:
    return [
        {"key": "application", "value": workload["application_name"]},
        {"key": "department", "value": workload["department_name"]},
        {"key": "environment", "value": workload["environment"]},
        {"key": "cost_center", "value": workload["cost_center"]},
        {"key": "owner", "value": workload["owner_team"]},
    ]


def _consumption_model(profile: pd.Series | None) -> dict[str, str]:
    if profile is None:
        return {
            "id": "modeled-on-demand",
            "description": "Modeled on-demand consumption",
        }

    return {
        "id": f"modeled-{profile['commitment_type'].lower()}",
        "description": f"Modeled {profile['commitment_type']}",
    }


def _usage_record(
    *,
    billing_account_id: str,
    project_id: str,
    project_name: str,
    region: str,
    date: pd.Timestamp,
    workload: pd.Series,
    service: pd.Series,
    quantity: float,
    cost_at_list: float,
    credits: list[dict[str, object]],
    profile: pd.Series | None,
    anomaly_name: str = "",
) -> dict[str, object]:
    usage_start = pd.Timestamp(date)
    usage_end = usage_start + pd.Timedelta(days=1)
    resource_name = _resource_name(service["resource_prefix"], workload.name)

    effective_price = (
        cost_at_list / quantity if quantity else float(service["list_rate"])
    )

    return {
        "source_record_id": _record_id(
            usage_start.date(), workload.name, service.name, "regular"
        ),
        "billing_account_id": billing_account_id,
        "service": {
            "id": service["service_id"],
            "description": service["service_description"],
        },
        "sku": {
            "id": service["sku_id"],
            "description": service["sku_description"],
        },
        "usage_start_time": usage_start.isoformat(),
        "usage_end_time": usage_end.isoformat(),
        "project": {
            "id": project_id,
            "number": _stable_number(project_id),
            "name": project_name,
        },
        "location": {
            "location": region,
            "country": "US",
            "region": region,
            "zone": "",
        },
        "resource": {
            "name": resource_name,
            "global_name": (
                f"//cloudresourcemanager.googleapis.com/projects/"
                f"{project_id}/resources/{resource_name}"
            ),
        },
        "labels": _label_array(workload),
        "system_labels": [],
        "tags": [],
        "cost": _money(cost_at_list),
        "cost_at_list": _money(cost_at_list),
        "currency": "USD",
        "currency_conversion_rate": 1.0,
        "usage": {
            "amount": round(float(quantity), 6),
            "unit": service["usage_unit"],
            "amount_in_pricing_units": round(float(quantity), 6),
            "pricing_unit": service["usage_unit"],
        },
        "credits": credits,
        "invoice": {"month": usage_start.strftime("%Y%m")},
        "cost_type": "regular",
        "adjustment_info": None,
        "price": {
            "effective_price": _money(effective_price),
            "tier_start_amount": 0.0,
            "unit": service["usage_unit"],
        },
        "consumption_model": _consumption_model(profile),
        "modeled_commitment_profile_id": "" if profile is None else profile.name,
        "modeled_cud_coverage_pct": (
            0.0 if profile is None else float(profile["coverage_pct"])
        ),
        "modeled_cud_utilization_pct": (
            0.0 if profile is None else float(profile["utilization_pct"])
        ),
        "modeled_unused_commitment_cost": 0.0,
        "is_synthetic": True,
        "is_late_arriving": False,
        "record_available_date": (usage_end + pd.Timedelta(days=1))
        .date()
        .isoformat(),
        "export_time": (usage_end + pd.Timedelta(days=1)).isoformat(),
        "data_quality_status": "VALID",
        "injected_scenario": anomaly_name,
    }


def _monthly_fee_record(
    *,
    billing_account_id: str,
    project_id: str,
    project_name: str,
    region: str,
    month_start: pd.Timestamp,
    workload: pd.Series,
    service: pd.Series,
    profile: pd.Series,
    fee_amount: float,
    unused_amount: float,
) -> dict[str, object]:
    month_end = month_start + pd.offsets.MonthBegin(1)
    return {
        "source_record_id": _record_id(
            month_start.date(), workload.name, service.name, profile.name, "fee"
        ),
        "billing_account_id": billing_account_id,
        "service": {
            "id": service["service_id"],
            "description": service["service_description"],
        },
        "sku": {
            "id": f"{service['sku_id']}-CUD-FEE",
            "description": f"{profile['commitment_type']} commitment fee",
        },
        "usage_start_time": month_start.isoformat(),
        "usage_end_time": month_end.isoformat(),
        "project": {
            "id": project_id,
            "number": _stable_number(project_id),
            "name": project_name,
        },
        "location": {
            "location": region,
            "country": "US",
            "region": region,
            "zone": "",
        },
        "resource": {
            "name": profile.name,
            "global_name": f"modeled://commitments/{profile.name}",
        },
        "labels": _label_array(workload),
        "system_labels": [],
        "tags": [],
        "cost": _money(fee_amount),
        "cost_at_list": 0.0,
        "currency": "USD",
        "currency_conversion_rate": 1.0,
        "usage": {
            "amount": 1.0,
            "unit": "month",
            "amount_in_pricing_units": 1.0,
            "pricing_unit": "month",
        },
        "credits": [],
        "invoice": {"month": month_start.strftime("%Y%m")},
        "cost_type": "regular",
        "adjustment_info": None,
        "price": {
            "effective_price": _money(fee_amount),
            "tier_start_amount": 0.0,
            "unit": "month",
        },
        "consumption_model": _consumption_model(profile),
        "modeled_commitment_profile_id": profile.name,
        "modeled_cud_coverage_pct": float(profile["coverage_pct"]),
        "modeled_cud_utilization_pct": float(profile["utilization_pct"]),
        "modeled_unused_commitment_cost": _money(unused_amount),
        "is_synthetic": True,
        "is_late_arriving": False,
        "record_available_date": (month_end + pd.Timedelta(days=2))
        .date()
        .isoformat(),
        "export_time": (month_end + pd.Timedelta(days=2)).isoformat(),
        "data_quality_status": "VALID",
        "injected_scenario": "modeled_cud_fee",
    }


def _marketplace_record(
    *,
    billing_account_id: str,
    project_id: str,
    project_name: str,
    region: str,
    month_start: pd.Timestamp,
    workload: pd.Series,
    service: pd.Series,
) -> dict[str, object]:
    month_end = month_start + pd.offsets.MonthBegin(1)
    fee_amount = float(service["list_rate"])
    return {
        "source_record_id": _record_id(
            month_start.date(), project_id, service.name, "marketplace"
        ),
        "billing_account_id": billing_account_id,
        "service": {
            "id": service["service_id"],
            "description": service["service_description"],
        },
        "sku": {
            "id": service["sku_id"],
            "description": service["sku_description"],
        },
        "usage_start_time": month_start.isoformat(),
        "usage_end_time": month_end.isoformat(),
        "project": {
            "id": project_id,
            "number": _stable_number(project_id),
            "name": project_name,
        },
        "location": {
            "location": region,
            "country": "US",
            "region": region,
            "zone": "",
        },
        "resource": {
            "name": _resource_name(service["resource_prefix"], workload.name),
            "global_name": f"modeled://marketplace/{service['sku_id']}",
        },
        "labels": _label_array(workload),
        "system_labels": [],
        "tags": [],
        "cost": _money(fee_amount),
        "cost_at_list": _money(fee_amount),
        "currency": "USD",
        "currency_conversion_rate": 1.0,
        "usage": {
            "amount": 1.0,
            "unit": "unit",
            "amount_in_pricing_units": 1.0,
            "pricing_unit": "unit",
        },
        "credits": [],
        "invoice": {"month": month_start.strftime("%Y%m")},
        "cost_type": "regular",
        "adjustment_info": None,
        "price": {
            "effective_price": _money(fee_amount),
            "tier_start_amount": 0.0,
            "unit": "unit",
        },
        "consumption_model": _consumption_model(None),
        "modeled_commitment_profile_id": "",
        "modeled_cud_coverage_pct": 0.0,
        "modeled_cud_utilization_pct": 0.0,
        "modeled_unused_commitment_cost": 0.0,
        "is_synthetic": True,
        "is_late_arriving": False,
        "record_available_date": (month_end + pd.Timedelta(days=2))
        .date()
        .isoformat(),
        "export_time": (month_end + pd.Timedelta(days=2)).isoformat(),
        "data_quality_status": "VALID",
        "injected_scenario": "marketplace_subscription",
    }


def _special_cost_record(
    *,
    billing_account_id: str,
    date: str,
    cost_type: str,
    amount: float,
    description: str,
    adjustment_type: str = "",
) -> dict[str, object]:
    timestamp = pd.Timestamp(date)
    usage_end = timestamp + pd.Timedelta(days=1)
    adjustment_info = None
    if cost_type == "adjustment":
        adjustment_info = {
            "id": _record_id(date, description),
            "description": description,
            "type": adjustment_type or "USAGE_CORRECTION",
            "mode": "COMPLETE_CORRECTION",
        }

    return {
        "source_record_id": _record_id(date, cost_type, description),
        "billing_account_id": billing_account_id,
        "service": {
            "id": "GCP-BILLING",
            "description": "Google Cloud Billing",
        },
        "sku": {
            "id": f"GCP-{cost_type.upper()}",
            "description": description,
        },
        "usage_start_time": timestamp.isoformat(),
        "usage_end_time": usage_end.isoformat(),
        "project": None,
        "location": {
            "location": "global",
            "country": "",
            "region": "",
            "zone": "",
        },
        "resource": None,
        "labels": [],
        "system_labels": [],
        "tags": [],
        "cost": _money(amount),
        "cost_at_list": 0.0,
        "currency": "USD",
        "currency_conversion_rate": 1.0,
        "usage": {
            "amount": 0.0,
            "unit": "",
            "amount_in_pricing_units": 0.0,
            "pricing_unit": "",
        },
        "credits": [],
        "invoice": {"month": timestamp.strftime("%Y%m")},
        "cost_type": cost_type,
        "adjustment_info": adjustment_info,
        "price": {
            "effective_price": 0.0,
            "tier_start_amount": 0.0,
            "unit": "",
        },
        "consumption_model": _consumption_model(None),
        "modeled_commitment_profile_id": "",
        "modeled_cud_coverage_pct": 0.0,
        "modeled_cud_utilization_pct": 0.0,
        "modeled_unused_commitment_cost": 0.0,
        "is_synthetic": True,
        "is_late_arriving": False,
        "record_available_date": (usage_end + pd.Timedelta(days=2))
        .date()
        .isoformat(),
        "export_time": (usage_end + pd.Timedelta(days=2)).isoformat(),
        "data_quality_status": "VALID",
        "injected_scenario": cost_type,
    }


def _credit_total(record: dict[str, object]) -> float:
    return sum(float(credit["amount"]) for credit in record["credits"])


def _apply_data_quality_scenarios(
    records: list[dict[str, object]],
    config: dict[str, Any],
    rng: np.random.Generator,
) -> list[dict[str, object]]:
    quality = config["data_quality"]
    usage_indexes = [
        index
        for index, record in enumerate(records)
        if record["cost_type"] == "regular"
        and record["usage"]["amount"] > 0
        and record["service"]["description"] != "Google Cloud Marketplace"
    ]

    missing_count = round(
        len(usage_indexes) * float(quality["missing_business_tags_pct"])
    )
    missing_indexes = rng.choice(
        usage_indexes, size=missing_count, replace=False
    )
    for index in missing_indexes:
        records[int(index)]["labels"] = []
        records[int(index)]["data_quality_status"] = "MISSING_LABELS"

    late_count = round(
        len(usage_indexes) * float(quality["late_arriving_records_pct"])
    )
    late_indexes = rng.choice(
        usage_indexes, size=late_count, replace=False
    )
    for index in late_indexes:
        record = records[int(index)]
        usage_end = pd.Timestamp(record["usage_end_time"])
        available = usage_end + pd.Timedelta(days=10)
        record["is_late_arriving"] = True
        record["record_available_date"] = available.date().isoformat()
        record["export_time"] = available.isoformat()

    valid_indexes = [
        index
        for index in usage_indexes
        if records[index]["data_quality_status"] == "VALID"
    ]
    invalid_count = int(quality["invalid_record_count"]["gcp"])
    invalid_indexes = rng.choice(
        valid_indexes, size=invalid_count, replace=False
    )
    for index in invalid_indexes:
        record = records[int(index)]
        record["usage"]["amount"] = -abs(float(record["usage"]["amount"]))
        record["usage"]["amount_in_pricing_units"] = record["usage"]["amount"]
        record["data_quality_status"] = "INVALID_NEGATIVE_USAGE"
        record["injected_scenario"] = "invalid_negative_usage"

    duplicate_count = int(quality["duplicate_record_count"]["gcp"])
    duplicate_indexes = rng.choice(
        valid_indexes, size=duplicate_count, replace=False
    )
    duplicates: list[dict[str, object]] = []
    for index in duplicate_indexes:
        duplicate = deepcopy(records[int(index)])
        duplicate["injected_scenario"] = "duplicate_record"
        duplicates.append(duplicate)

    records.extend(duplicates)
    return records


def _write_jsonl(path: Path, records: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as file:
        for record in records:
            file.write(
                json.dumps(
                    record,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=False,
                )
            )
            file.write("\n")


def generate_gcp_billing(
    config_dir: Path,
    output_dir: Path,
) -> dict[str, object]:
    """Generate GCP source-shaped billing data and return control totals."""
    config = _read_yaml(config_dir / "generator_config.yaml")
    seed = int(config["project"]["seed"]) + 200
    rng = np.random.default_rng(seed)

    dimensions = _read_csv(config_dir / "business_dimensions.csv").set_index(
        "workload_id"
    )
    projects = _read_csv(config_dir / "gcp_projects.csv").set_index(
        "project_id"
    )
    mappings = _read_csv(config_dir / "gcp_workload_mapping.csv").set_index(
        "workload_id"
    )
    services = _read_csv(config_dir / "gcp_service_pricing.csv").set_index(
        "service_code"
    )
    profiles = _read_csv(config_dir / "commitment_profiles.csv").set_index(
        "profile_id"
    )
    assignments = _read_csv(
        config_dir / "gcp_commitment_assignments.csv"
    )
    assignment_lookup = {
        (row["workload_id"], row["service_code"]): row["profile_id"]
        for _, row in assignments.iterrows()
    }

    business_activity_file = (
        output_dir.parents[1] / "business_activity" / "business_activity.csv"
    )
    activity = generate_business_activity(
        config_dir, business_activity_file
    )
    activity["activity_date"] = pd.to_datetime(activity["activity_date"])
    activity = activity.set_index(["activity_date", "workload_id"])

    dates = pd.date_range(
        config["generation_period"]["start_date"],
        config["generation_period"]["end_date"],
        freq="D",
    )

    records: list[dict[str, object]] = []
    monthly_profile_usage: dict[
        tuple[pd.Timestamp, str, str, str], float
    ] = {}

    for workload_id, mapping in mappings.iterrows():
        workload = dimensions.loc[workload_id].copy()
        workload.name = workload_id
        project = projects.loc[mapping["project_id"]]
        service_codes = mapping["service_codes"].split("|")
        scale_factor = float(mapping["scale_factor"])

        for service_code in service_codes:
            service = services.loc[service_code].copy()
            service.name = service_code

            if service_code == "GCPMarketplace":
                for month_start in pd.date_range(
                    dates.min(), dates.max(), freq="MS"
                ):
                    records.append(
                        _marketplace_record(
                            billing_account_id=project["billing_account_id"],
                            project_id=mapping["project_id"],
                            project_name=project["project_name"],
                            region=mapping["region"],
                            month_start=month_start,
                            workload=workload,
                            service=service,
                        )
                    )
                continue

            profile_id = assignment_lookup.get((workload_id, service_code), "")
            profile = None
            if profile_id:
                profile = profiles.loc[profile_id].copy()
                profile.name = profile_id

            for date in dates:
                activity_row = activity.loc[(date, workload_id)]
                demand_index = float(activity_row["demand_index"])
                quantity = (
                    float(service["base_daily_usage"])
                    * demand_index
                    * scale_factor
                )

                anomaly_name = ""
                anomaly_factor = ANOMALY_FACTORS.get(
                    (date.date().isoformat(), workload_id, service_code), 1.0
                )
                if anomaly_factor != 1.0:
                    quantity *= anomaly_factor
                    anomaly_name = f"{service_code.lower()}_spike"

                list_cost = quantity * float(service["list_rate"])
                credits: list[dict[str, object]] = []

                if profile is not None:
                    coverage = float(profile["coverage_pct"])
                    covered_cost = list_cost * coverage
                    credits.append(
                        {
                            "id": _record_id(
                                date.date(), workload_id, service_code, profile_id
                            ),
                            "full_name": (
                                f"Modeled {profile['commitment_type']} usage offset"
                            ),
                            "type": "COMMITTED_USAGE_DISCOUNT",
                            "name": profile["commitment_type"],
                            "amount": _money(-covered_cost),
                        }
                    )

                    month_start = date.replace(day=1)
                    key = (month_start, workload_id, service_code, profile_id)
                    monthly_profile_usage[key] = (
                        monthly_profile_usage.get(key, 0.0) + covered_cost
                    )

                    if date.day == 15:
                        uncovered_cost = list_cost - covered_cost
                        if uncovered_cost > 0:
                            credits.append(
                                {
                                    "id": _record_id(
                                        date.date(),
                                        workload_id,
                                        service_code,
                                        "enterprise-discount",
                                    ),
                                    "full_name": "Modeled enterprise discount",
                                    "type": "DISCOUNT",
                                    "name": "Enterprise discount",
                                    "amount": _money(-uncovered_cost * 0.03),
                                }
                            )

                records.append(
                    _usage_record(
                        billing_account_id=project["billing_account_id"],
                        project_id=mapping["project_id"],
                        project_name=project["project_name"],
                        region=mapping["region"],
                        date=date,
                        workload=workload,
                        service=service,
                        quantity=quantity,
                        cost_at_list=list_cost,
                        credits=credits,
                        profile=profile,
                        anomaly_name=anomaly_name,
                    )
                )

    for (
        month_start,
        workload_id,
        service_code,
        profile_id,
    ), covered_list_cost in sorted(monthly_profile_usage.items()):
        mapping = mappings.loc[workload_id]
        workload = dimensions.loc[workload_id].copy()
        workload.name = workload_id
        project = projects.loc[mapping["project_id"]]
        service = services.loc[service_code].copy()
        service.name = service_code
        profile = profiles.loc[profile_id].copy()
        profile.name = profile_id

        utilization = float(profile["utilization_pct"])
        discount = float(profile["discount_pct"])
        purchased_list_equivalent = covered_list_cost / utilization
        fee_amount = purchased_list_equivalent * (1.0 - discount)
        used_commitment_cost = covered_list_cost * (1.0 - discount)
        unused_amount = max(0.0, fee_amount - used_commitment_cost)

        records.append(
            _monthly_fee_record(
                billing_account_id=project["billing_account_id"],
                project_id=mapping["project_id"],
                project_name=project["project_name"],
                region=mapping["region"],
                month_start=month_start,
                workload=workload,
                service=service,
                profile=profile,
                fee_amount=fee_amount,
                unused_amount=unused_amount,
            )
        )

    billing_account_id = projects.iloc[0]["billing_account_id"]

    usage_by_month: dict[str, float] = {}
    for record in records:
        if record["cost_type"] != "regular":
            continue
        month = record["invoice"]["month"]
        net_cost = float(record["cost"]) + _credit_total(record)
        usage_by_month[month] = usage_by_month.get(month, 0.0) + net_cost

    for month, month_net_cost in sorted(usage_by_month.items()):
        month_start = pd.Timestamp(f"{month[:4]}-{month[4:]}-01")
        records.append(
            _special_cost_record(
                billing_account_id=billing_account_id,
                date=month_start.date().isoformat(),
                cost_type="tax",
                amount=max(month_net_cost, 0.0) * 0.012,
                description=f"Modeled cloud tax for invoice {month}",
            )
        )

    records.extend(
        [
            _special_cost_record(
                billing_account_id=billing_account_id,
                date="2026-01-15",
                cost_type="adjustment",
                amount=-425.75,
                description="Modeled service usage correction",
                adjustment_type="USAGE_CORRECTION",
            ),
            _special_cost_record(
                billing_account_id=billing_account_id,
                date="2026-06-30",
                cost_type="rounding_error",
                amount=0.01,
                description="Modeled invoice rounding correction",
            ),
        ]
    )

    records = _apply_data_quality_scenarios(records, config, rng)

    records.sort(
        key=lambda record: (
            record["usage_start_time"],
            "" if record["project"] is None else record["project"]["id"],
            record["service"]["description"],
            record["sku"]["description"],
            record["source_record_id"],
        )
    )

    output_file = output_dir / "gcp_billing.jsonl"
    _write_jsonl(output_file, records)

    regular_usage = [
        record
        for record in records
        if record["cost_type"] == "regular"
        and record["usage"]["amount"] != 0
        and record["service"]["description"] != "Google Cloud Marketplace"
    ]
    usage_dates = {
        pd.Timestamp(record["usage_start_time"]).date().isoformat()
        for record in regular_usage
    }
    source_ids = pd.Series(
        [record["source_record_id"] for record in records]
    ).value_counts()

    total_cost = _money(sum(float(record["cost"]) for record in records))
    total_credit = _money(sum(_credit_total(record) for record in records))
    total_net = _money(total_cost + total_credit)

    summary: dict[str, object] = {
        "provider": "GCP",
        "source_format": "newline_delimited_json",
        "date_range": {
            "start": min(usage_dates),
            "end": max(usage_dates),
        },
        "distinct_usage_dates": len(usage_dates),
        "row_count": len(records),
        "total_cost_before_credits": total_cost,
        "total_credit_amount": total_credit,
        "total_net_cost": total_net,
        "cost_type_counts": dict(
            sorted(
                pd.Series([record["cost_type"] for record in records])
                .value_counts()
                .astype(int)
                .to_dict()
                .items()
            )
        ),
        "service_counts": dict(
            sorted(
                pd.Series(
                    [record["service"]["description"] for record in records]
                )
                .value_counts()
                .astype(int)
                .to_dict()
                .items()
            )
        ),
        "missing_label_rows": sum(
            record["data_quality_status"] == "MISSING_LABELS"
            for record in records
        ),
        "late_arriving_rows": sum(
            bool(record["is_late_arriving"]) for record in records
        ),
        "invalid_rows": sum(
            record["data_quality_status"] == "INVALID_NEGATIVE_USAGE"
            for record in records
        ),
        "duplicated_source_record_ids": int((source_ids > 1).sum()),
        "injected_anomaly_rows": sum(
            str(record["injected_scenario"]).endswith("_spike")
            for record in records
        ),
        "rows_with_multiple_credits": sum(
            len(record["credits"]) > 1 for record in records
        ),
        "commitment_profiles": sorted(
            {
                record["modeled_commitment_profile_id"]
                for record in records
                if record["modeled_commitment_profile_id"]
            }
        ),
        "modeled_unused_commitment_cost": _money(
            sum(
                float(record["modeled_unused_commitment_cost"])
                for record in records
            )
        ),
        "nested_field_controls": {
            "labels_are_repeated": True,
            "credits_are_repeated": True,
            "project_is_struct": True,
            "usage_is_struct": True,
            "cross_unnest_warning": (
                "Pre-aggregate or unnest labels and credits separately to avoid "
                "multiplying billing rows."
            ),
        },
    }

    summary_file = output_dir / "gcp_generator_validation_summary.json"
    summary_file.parent.mkdir(parents=True, exist_ok=True)
    summary_file.write_text(
        json.dumps(summary, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    return summary


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    summary = generate_gcp_billing(
        root / "config",
        root / "data" / "synthetic_enterprise_usage" / "gcp",
    )
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

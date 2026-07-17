
"""Generate deterministic AWS CUR-style synthetic billing data."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any
from uuid import NAMESPACE_URL, uuid5

import numpy as np
import pandas as pd
import yaml

from generator.business_activity import generate_business_activity


ANOMALY_FACTORS = {
    ("2026-02-17", "shared-platform-prod", "AmazonVPC"): 3.8,
    ("2026-03-14", "shared-platform-prod", "AmazonCloudWatch"): 4.5,
    ("2026-05-10", "recommendations-prod", "AmazonBedrock"): 5.0,
}


def _read_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return yaml.safe_load(file)


def _read_csv(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, dtype=str)


def _line_item_id(*parts: object) -> str:
    key = "|".join(str(part) for part in parts)
    return str(uuid5(NAMESPACE_URL, key))


def _resource_id(prefix: str, workload_id: str, sequence: int = 1) -> str:
    stable = hashlib.sha1(
        f"{prefix}|{workload_id}|{sequence}".encode("utf-8")
    ).hexdigest()[:12]
    return f"{prefix}-{stable}"


def _money(value: float) -> float:
    return round(float(value), 6)


def _build_usage_row(
    *,
    payer_account_id: str,
    usage_account_id: str,
    date: pd.Timestamp,
    region: str,
    workload: pd.Series,
    service: pd.Series,
    quantity: float,
    line_item_type: str,
    public_cost: float,
    billed_cost: float,
    reservation_effective_cost: float = 0.0,
    savings_plan_effective_cost: float = 0.0,
    pricing_term: str = "OnDemand",
    purchase_option: str = "OnDemand",
    commitment_profile_id: str = "",
    anomaly_name: str = "",
) -> dict[str, object]:
    resource_id = _resource_id(
        service["resource_prefix"], workload.name
    )
    usage_start = pd.Timestamp(date)
    usage_end = usage_start + pd.Timedelta(days=1)
    period_start = usage_start.replace(day=1)
    period_end = period_start + pd.offsets.MonthBegin(1)

    return {
        "bill_payer_account_id": payer_account_id,
        "bill_billing_period_start_date": period_start.date().isoformat(),
        "bill_billing_period_end_date": period_end.date().isoformat(),
        "line_item_usage_account_id": usage_account_id,
        "line_item_line_item_id": _line_item_id(
            usage_start.date(),
            workload.name,
            service.name,
            line_item_type,
            commitment_profile_id,
        ),
        "line_item_usage_start_date": usage_start.isoformat(),
        "line_item_usage_end_date": usage_end.isoformat(),
        "line_item_line_item_type": line_item_type,
        "line_item_product_code": service.name,
        "product_product_name": service["product_name"],
        "product_region": region,
        "line_item_resource_id": resource_id,
        "line_item_usage_type": service["usage_type"],
        "line_item_operation": service["operation"],
        "line_item_line_item_description": (
            f"{service['product_name']} usage for {workload['application_name']}"
        ),
        "pricing_unit": service["pricing_unit"],
        "line_item_usage_amount": round(float(quantity), 6),
        "pricing_public_on_demand_rate": _money(service["list_rate"]),
        "pricing_public_on_demand_cost": _money(public_cost),
        "line_item_unblended_rate": (
            _money(billed_cost / quantity) if quantity else 0.0
        ),
        "line_item_unblended_cost": _money(billed_cost),
        "reservation_effective_cost": _money(reservation_effective_cost),
        "reservation_unused_recurring_fee": 0.0,
        "savings_plan_savings_plan_effective_cost": _money(
            savings_plan_effective_cost
        ),
        "savings_plan_unused_commitment": 0.0,
        "line_item_currency_code": "USD",
        "pricing_term": pricing_term,
        "pricing_purchase_option": purchase_option,
        "commitment_profile_id": commitment_profile_id,
        "resource_tags_user_application": workload["application_name"],
        "resource_tags_user_department": workload["department_name"],
        "resource_tags_user_environment": workload["environment"],
        "resource_tags_user_cost_center": workload["cost_center"],
        "resource_tags_user_owner": workload["owner_team"],
        "is_synthetic": True,
        "is_late_arriving": False,
        "record_available_date": (usage_end + pd.Timedelta(days=1))
        .date()
        .isoformat(),
        "data_quality_status": "VALID",
        "injected_scenario": anomaly_name,
    }


def _fee_row(
    *,
    payer_account_id: str,
    usage_account_id: str,
    month_start: pd.Timestamp,
    workload: pd.Series,
    service: pd.Series,
    profile: pd.Series,
    fee_amount: float,
    unused_amount: float,
    region: str,
) -> dict[str, object]:
    line_item_type = (
        "SavingsPlanRecurringFee"
        if profile["commitment_type"] == "SavingsPlan"
        else "RIFee"
    )
    month_end = month_start + pd.offsets.MonthBegin(1)
    row = _build_usage_row(
        payer_account_id=payer_account_id,
        usage_account_id=usage_account_id,
        date=month_start,
        region=region,
        workload=workload,
        service=service,
        quantity=0.0,
        line_item_type=line_item_type,
        public_cost=0.0,
        billed_cost=fee_amount,
        pricing_term=profile["commitment_type"],
        purchase_option="Commitment",
        commitment_profile_id=profile.name,
    )
    row["line_item_line_item_id"] = _line_item_id(
        month_start.date(), profile.name, line_item_type
    )
    row["line_item_usage_end_date"] = month_end.isoformat()
    row["line_item_line_item_description"] = (
        f"Monthly {profile['commitment_type']} fee for "
        f"{workload['application_name']}"
    )
    row["line_item_resource_id"] = profile.name
    if line_item_type == "SavingsPlanRecurringFee":
        row["savings_plan_unused_commitment"] = _money(unused_amount)
    else:
        row["reservation_unused_recurring_fee"] = _money(unused_amount)
    return row


def _adjustment_row(
    *,
    payer_account_id: str,
    usage_account_id: str,
    date: str,
    line_item_type: str,
    amount: float,
    description: str,
) -> dict[str, object]:
    timestamp = pd.Timestamp(date)
    period_start = timestamp.replace(day=1)
    period_end = period_start + pd.offsets.MonthBegin(1)

    return {
        "bill_payer_account_id": payer_account_id,
        "bill_billing_period_start_date": period_start.date().isoformat(),
        "bill_billing_period_end_date": period_end.date().isoformat(),
        "line_item_usage_account_id": usage_account_id,
        "line_item_line_item_id": _line_item_id(
            date, line_item_type, description
        ),
        "line_item_usage_start_date": timestamp.isoformat(),
        "line_item_usage_end_date": (
            timestamp + pd.Timedelta(days=1)
        ).isoformat(),
        "line_item_line_item_type": line_item_type,
        "line_item_product_code": "AWSBilling",
        "product_product_name": "AWS Billing",
        "product_region": "global",
        "line_item_resource_id": "",
        "line_item_usage_type": "",
        "line_item_operation": "",
        "line_item_line_item_description": description,
        "pricing_unit": "",
        "line_item_usage_amount": 0.0,
        "pricing_public_on_demand_rate": 0.0,
        "pricing_public_on_demand_cost": 0.0,
        "line_item_unblended_rate": 0.0,
        "line_item_unblended_cost": _money(amount),
        "reservation_effective_cost": 0.0,
        "reservation_unused_recurring_fee": 0.0,
        "savings_plan_savings_plan_effective_cost": 0.0,
        "savings_plan_unused_commitment": 0.0,
        "line_item_currency_code": "USD",
        "pricing_term": "",
        "pricing_purchase_option": "",
        "commitment_profile_id": "",
        "resource_tags_user_application": "",
        "resource_tags_user_department": "",
        "resource_tags_user_environment": "",
        "resource_tags_user_cost_center": "",
        "resource_tags_user_owner": "",
        "is_synthetic": True,
        "is_late_arriving": False,
        "record_available_date": (
            timestamp + pd.Timedelta(days=2)
        ).date().isoformat(),
        "data_quality_status": "VALID",
        "injected_scenario": line_item_type.lower(),
    }


def _apply_data_quality_scenarios(
    billing: pd.DataFrame,
    config: dict[str, Any],
    rng: np.random.Generator,
) -> pd.DataFrame:
    quality = config["data_quality"]

    usage_mask = billing["line_item_line_item_type"].isin(
        ["Usage", "DiscountedUsage", "SavingsPlanCoveredUsage"]
    )
    usage_indexes = billing.index[usage_mask].to_numpy()

    missing_count = round(
        len(usage_indexes) * float(quality["missing_business_tags_pct"])
    )
    missing_indexes = rng.choice(
        usage_indexes, size=missing_count, replace=False
    )
    tag_columns = [
        "resource_tags_user_application",
        "resource_tags_user_department",
        "resource_tags_user_environment",
        "resource_tags_user_cost_center",
        "resource_tags_user_owner",
    ]
    billing.loc[missing_indexes, tag_columns] = ""
    billing.loc[missing_indexes, "data_quality_status"] = "MISSING_TAGS"

    late_count = round(
        len(billing) * float(quality["late_arriving_records_pct"])
    )
    late_indexes = rng.choice(
        billing.index.to_numpy(), size=late_count, replace=False
    )
    late_days = rng.integers(4, 11, size=late_count)
    usage_end = pd.to_datetime(
        billing.loc[late_indexes, "line_item_usage_end_date"]
    )
    billing.loc[late_indexes, "is_late_arriving"] = True
    billing.loc[late_indexes, "record_available_date"] = [
        (date + pd.Timedelta(days=int(days))).date().isoformat()
        for date, days in zip(usage_end, late_days)
    ]

    invalid_count = int(quality["invalid_record_count"]["aws"])
    valid_usage = billing.index[
        billing["line_item_line_item_type"] == "Usage"
    ].to_numpy()
    invalid_source_indexes = rng.choice(
        valid_usage, size=invalid_count, replace=False
    )
    invalid_rows = billing.loc[invalid_source_indexes].copy()
    invalid_rows["line_item_line_item_id"] = [
        _line_item_id(original_id, "invalid-negative-usage")
        for original_id in invalid_rows["line_item_line_item_id"]
    ]
    invalid_rows["line_item_usage_amount"] = (
        invalid_rows["line_item_usage_amount"].astype(float).abs() * -1
    )
    invalid_rows["data_quality_status"] = "INVALID_NEGATIVE_USAGE"
    invalid_rows["injected_scenario"] = "invalid_negative_usage"
    billing = pd.concat([billing, invalid_rows], ignore_index=True)

    duplicate_count = int(quality["duplicate_record_count"]["aws"])
    duplicate_source_indexes = rng.choice(
        billing.index[billing["data_quality_status"] == "VALID"].to_numpy(),
        size=duplicate_count,
        replace=False,
    )
    duplicate_rows = billing.loc[duplicate_source_indexes].copy()
    duplicate_rows["injected_scenario"] = "duplicate_record"
    billing = pd.concat([billing, duplicate_rows], ignore_index=True)

    return billing


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def generate_aws_billing(
    config_dir: Path,
    output_dir: Path,
) -> dict[str, Any]:
    """Generate AWS-only source-style billing data and provider controls."""
    config = _read_yaml(config_dir / "generator_config.yaml")
    seed = int(config["project"]["seed"])
    rng = np.random.default_rng(seed + 100)

    dimensions = _read_csv(config_dir / "business_dimensions.csv")
    accounts = _read_csv(config_dir / "aws_accounts.csv")
    mappings = _read_csv(config_dir / "aws_workload_mapping.csv")
    services = pd.read_csv(config_dir / "aws_service_pricing.csv")
    profiles = pd.read_csv(config_dir / "commitment_profiles.csv")
    assignments = _read_csv(config_dir / "aws_commitment_assignments.csv")

    dimensions_by_workload = dimensions.set_index("workload_id")
    accounts_by_usage = accounts.set_index("usage_account_id")
    services_by_code = services.set_index("service_code")
    profiles_by_id = profiles.set_index("profile_id")
    assignment_lookup = {
        (row["workload_id"], row["service_code"]): row["profile_id"]
        for _, row in assignments.iterrows()
    }

    business_activity_file = (
        output_dir.parent.parent / "business_activity" / "business_activity.csv"
    )
    activity = generate_business_activity(
        config_dir=config_dir,
        output_file=business_activity_file,
    )
    activity["activity_date"] = pd.to_datetime(activity["activity_date"])
    activity_lookup = activity.set_index(
        ["activity_date", "workload_id"]
    )["demand_index"]

    start_date = pd.Timestamp(config["generation_period"]["start_date"])
    end_date = pd.Timestamp(config["generation_period"]["end_date"])
    dates = pd.date_range(start_date, end_date, freq="D")

    rows: list[dict[str, object]] = []
    commitment_usage: dict[tuple[str, str, str], dict[str, float]] = {}

    payer_account_id = accounts["payer_account_id"].iloc[0]

    for _, mapping in mappings.iterrows():
        workload = dimensions_by_workload.loc[mapping["workload_id"]]
        usage_account_id = mapping["usage_account_id"]
        if usage_account_id not in accounts_by_usage.index:
            raise ValueError(
                f"Unknown AWS usage account: {usage_account_id}"
            )

        for service_code in mapping["service_codes"].split("|"):
            service = services_by_code.loc[service_code]
            list_rate = float(service["list_rate"])
            base_daily_usage = float(service["base_daily_usage"])
            scale_factor = float(mapping["scale_factor"])
            profile_id = assignment_lookup.get(
                (mapping["workload_id"], service_code), ""
            )
            profile = (
                profiles_by_id.loc[profile_id]
                if profile_id
                else None
            )

            for date in dates:
                demand_index = float(
                    activity_lookup.loc[(date, mapping["workload_id"])]
                )
                quantity = base_daily_usage * scale_factor * demand_index

                anomaly_key = (
                    date.date().isoformat(),
                    mapping["workload_id"],
                    service_code,
                )
                anomaly_factor = ANOMALY_FACTORS.get(anomaly_key, 1.0)
                quantity *= anomaly_factor
                anomaly_name = (
                    f"aws_{service_code.lower()}_spike"
                    if anomaly_factor > 1
                    else ""
                )

                public_cost = quantity * list_rate

                if profile is None:
                    rows.append(
                        _build_usage_row(
                            payer_account_id=payer_account_id,
                            usage_account_id=usage_account_id,
                            date=date,
                            region=mapping["region"],
                            workload=workload,
                            service=service,
                            quantity=quantity,
                            line_item_type="Usage",
                            public_cost=public_cost,
                            billed_cost=public_cost,
                            anomaly_name=anomaly_name,
                        )
                    )
                    continue

                coverage_pct = float(profile["coverage_pct"])
                discount_pct = float(profile["discount_pct"])
                covered_quantity = quantity * coverage_pct
                uncovered_quantity = quantity - covered_quantity
                covered_public_cost = covered_quantity * list_rate
                covered_effective_cost = covered_public_cost * (
                    1.0 - discount_pct
                )

                covered_type = (
                    "SavingsPlanCoveredUsage"
                    if profile["commitment_type"] == "SavingsPlan"
                    else "DiscountedUsage"
                )
                rows.append(
                    _build_usage_row(
                        payer_account_id=payer_account_id,
                        usage_account_id=usage_account_id,
                        date=date,
                        region=mapping["region"],
                        workload=workload,
                        service=service,
                        quantity=covered_quantity,
                        line_item_type=covered_type,
                        public_cost=covered_public_cost,
                        billed_cost=0.0,
                        reservation_effective_cost=(
                            covered_effective_cost
                            if covered_type == "DiscountedUsage"
                            else 0.0
                        ),
                        savings_plan_effective_cost=(
                            covered_effective_cost
                            if covered_type == "SavingsPlanCoveredUsage"
                            else 0.0
                        ),
                        pricing_term=profile["commitment_type"],
                        purchase_option="Commitment",
                        commitment_profile_id=profile_id,
                        anomaly_name=anomaly_name,
                    )
                )

                if uncovered_quantity > 0:
                    rows.append(
                        _build_usage_row(
                            payer_account_id=payer_account_id,
                            usage_account_id=usage_account_id,
                            date=date,
                            region=mapping["region"],
                            workload=workload,
                            service=service,
                            quantity=uncovered_quantity,
                            line_item_type="Usage",
                            public_cost=uncovered_quantity * list_rate,
                            billed_cost=uncovered_quantity * list_rate,
                            anomaly_name=anomaly_name,
                        )
                    )

                month_key = date.to_period("M").strftime("%Y-%m")
                key = (
                    month_key,
                    mapping["workload_id"],
                    profile_id,
                )
                commitment_usage.setdefault(
                    key,
                    {
                        "covered_effective_cost": 0.0,
                        "usage_account_id": usage_account_id,
                        "region": mapping["region"],
                        "service_code": service_code,
                    },
                )
                commitment_usage[key]["covered_effective_cost"] += (
                    covered_effective_cost
                )

    for (
        month_key,
        workload_id,
        profile_id,
    ), values in commitment_usage.items():
        profile = profiles_by_id.loc[profile_id]
        utilization_pct = float(profile["utilization_pct"])
        covered_effective_cost = float(values["covered_effective_cost"])
        fee_amount = covered_effective_cost / utilization_pct
        unused_amount = fee_amount - covered_effective_cost
        rows.append(
            _fee_row(
                payer_account_id=payer_account_id,
                usage_account_id=str(values["usage_account_id"]),
                month_start=pd.Timestamp(f"{month_key}-01"),
                workload=dimensions_by_workload.loc[workload_id],
                service=services_by_code.loc[str(values["service_code"])],
                profile=profile,
                fee_amount=fee_amount,
                unused_amount=unused_amount,
                region=str(values["region"]),
            )
        )

    marketplace = services_by_code.loc["AWSMarketplace"]
    shared_mapping = mappings[
        mappings["workload_id"] == "shared-platform-prod"
    ].iloc[0]
    shared_workload = dimensions_by_workload.loc["shared-platform-prod"]

    for month_start in pd.date_range(
        start_date, end_date, freq="MS"
    ):
        rows.append(
            _build_usage_row(
                payer_account_id=payer_account_id,
                usage_account_id=shared_mapping["usage_account_id"],
                date=month_start,
                region=shared_mapping["region"],
                workload=shared_workload,
                service=marketplace,
                quantity=1.0,
                line_item_type="Fee",
                public_cost=0.0,
                billed_cost=float(marketplace["list_rate"]),
                pricing_term="Subscription",
                purchase_option="Marketplace",
            )
        )

    rows.extend(
        [
            _adjustment_row(
                payer_account_id=payer_account_id,
                usage_account_id="111111111114",
                date="2026-01-15",
                line_item_type="Credit",
                amount=-1500.0,
                description="AWS promotional service credit",
            ),
            _adjustment_row(
                payer_account_id=payer_account_id,
                usage_account_id="111111111112",
                date="2026-04-08",
                line_item_type="Refund",
                amount=-825.0,
                description="Refund for prior-period service issue",
            ),
        ]
    )

    billing = pd.DataFrame(rows)
    billing = _apply_data_quality_scenarios(
        billing=billing,
        config=config,
        rng=rng,
    )

    billing = billing.sort_values(
        [
            "line_item_usage_start_date",
            "line_item_usage_account_id",
            "line_item_product_code",
            "line_item_line_item_id",
        ]
    ).reset_index(drop=True)

    output_dir.mkdir(parents=True, exist_ok=True)
    billing_file = output_dir / "aws_billing.csv"
    summary_file = output_dir / "aws_generator_validation_summary.json"
    billing.to_csv(billing_file, index=False)

    duplicated_ids = int(
        (billing["line_item_line_item_id"].value_counts() > 1).sum()
    )
    usage_dates = pd.to_datetime(
        billing.loc[
            billing["line_item_line_item_type"].isin(
                ["Usage", "DiscountedUsage", "SavingsPlanCoveredUsage"]
            ),
            "line_item_usage_start_date",
        ]
    ).dt.date

    summary: dict[str, Any] = {
        "provider": "AWS",
        "seed": seed,
        "start_date": start_date.date().isoformat(),
        "end_date": end_date.date().isoformat(),
        "distinct_usage_dates": int(pd.Series(usage_dates).nunique()),
        "row_count": int(len(billing)),
        "total_public_on_demand_cost": _money(
            billing["pricing_public_on_demand_cost"].sum()
        ),
        "total_billed_cost": _money(
            billing["line_item_unblended_cost"].sum()
        ),
        "line_item_type_counts": {
            str(key): int(value)
            for key, value in billing[
                "line_item_line_item_type"
            ].value_counts().sort_index().items()
        },
        "missing_tag_rows": int(
            (billing["data_quality_status"] == "MISSING_TAGS").sum()
        ),
        "late_arriving_rows": int(billing["is_late_arriving"].sum()),
        "invalid_rows": int(
            (
                billing["data_quality_status"]
                == "INVALID_NEGATIVE_USAGE"
            ).sum()
        ),
        "duplicated_line_item_ids": duplicated_ids,
        "injected_anomaly_rows": int(
            billing["injected_scenario"].str.contains(
                "_spike", na=False
            ).sum()
        ),
        "commitment_profiles": sorted(
            billing.loc[
                billing["commitment_profile_id"] != "",
                "commitment_profile_id",
            ].unique().tolist()
        ),
    }

    summary_file.write_text(
        json.dumps(summary, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    summary["aws_billing_sha256"] = _sha256(billing_file)
    summary_file.write_text(
        json.dumps(summary, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    return summary


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    summary = generate_aws_billing(
        config_dir=root / "config",
        output_dir=(
            root
            / "data"
            / "synthetic_enterprise_usage"
            / "aws"
        ),
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

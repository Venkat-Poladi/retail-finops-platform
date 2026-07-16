from pathlib import Path

import pandas as pd
import yaml


ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "config"


def read_yaml(filename: str) -> dict:
    """Read a YAML configuration file."""
    with (CONFIG_DIR / filename).open("r", encoding="utf-8") as file:
        return yaml.safe_load(file)


def read_csv(filename: str) -> pd.DataFrame:
    """Read a CSV configuration file while preserving identifier strings."""
    return pd.read_csv(CONFIG_DIR / filename, dtype=str)


def test_generation_period_is_exactly_twelve_complete_months() -> None:
    config = read_yaml("generator_config.yaml")
    start_date = pd.Timestamp(config["generation_period"]["start_date"])
    end_date = pd.Timestamp(config["generation_period"]["end_date"])

    expected_end_date = (
        start_date + pd.DateOffset(months=12) - pd.Timedelta(days=1)
    )

    assert start_date.day == 1
    assert end_date == expected_end_date


def test_business_dimensions_have_unique_workload_ids() -> None:
    dimensions = read_csv("business_dimensions.csv")

    required_columns = {
        "workload_id",
        "application_name",
        "department_name",
        "cost_center",
        "environment",
        "owner_team",
        "is_shared",
        "criticality",
        "business_driver",
    }

    assert required_columns.issubset(dimensions.columns)
    assert dimensions["workload_id"].is_unique
    assert dimensions["workload_id"].notna().all()
    assert set(dimensions["environment"]) == {"prod", "nonprod"}


def test_aws_and_gcp_hierarchies_are_not_treated_as_equivalent() -> None:
    aws_accounts = read_csv("aws_accounts.csv")
    gcp_projects = read_csv("gcp_projects.csv")

    assert {
        "payer_account_id",
        "usage_account_id",
    }.issubset(aws_accounts.columns)

    assert {
        "billing_account_id",
        "project_id",
    }.issubset(gcp_projects.columns)

    assert "project_id" not in aws_accounts.columns
    assert "usage_account_id" not in gcp_projects.columns

    assert aws_accounts["usage_account_id"].is_unique
    assert gcp_projects["project_id"].is_unique


def test_source_billing_contracts_preserve_provider_differences() -> None:
    contracts = read_yaml("source_billing_contracts.yaml")

    aws = contracts["aws"]
    gcp = contracts["gcp"]

    assert (
        aws["billing_hierarchy"]["billing_account_field"]
        == "bill_payer_account_id"
    )
    assert (
        aws["billing_hierarchy"]["usage_account_field"]
        == "line_item_usage_account_id"
    )

    assert (
        gcp["billing_hierarchy"]["billing_account_field"]
        == "billing_account_id"
    )
    assert gcp["billing_hierarchy"]["project_field"] == "project.id"

    assert aws["credits"]["representation"] == "separate_line_item"
    assert gcp["credits"]["representation"] == "nested_repeated_array"

    assert aws["source_shape"]["nested_fields"] is False
    assert gcp["source_shape"]["nested_fields"] is True


def test_service_catalog_contains_both_providers() -> None:
    services = read_csv("service_catalog.csv")

    assert set(services["provider_name"]) == {"AWS", "GCP"}

    service_counts = services.groupby("provider_name").size()

    assert service_counts["AWS"] >= 8
    assert service_counts["GCP"] >= 8

    assert {"Compute", "Database", "Storage", "Network", "AI"}.issubset(
        set(services["service_category"])
    )


def test_commitment_profiles_include_realistic_variation() -> None:
    profiles = pd.read_csv(CONFIG_DIR / "commitment_profiles.csv")

    assert set(profiles["provider_name"]) == {"AWS", "GCP"}

    assert {
        "balanced",
        "under_committed",
        "over_committed",
    }.issubset(set(profiles["profile_name"]))

    for column in ["coverage_pct", "utilization_pct", "discount_pct"]:
        assert profiles[column].between(0, 1).all()

    under_committed = profiles[
        profiles["profile_name"] == "under_committed"
    ]

    over_committed = profiles[
        profiles["profile_name"] == "over_committed"
    ]

    assert (
        under_committed["utilization_pct"]
        > under_committed["coverage_pct"]
    ).all()

    assert (
        over_committed["coverage_pct"]
        > over_committed["utilization_pct"]
    ).all()
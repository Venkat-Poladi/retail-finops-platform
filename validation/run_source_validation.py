"""Run AWS and GCP source validations without unioning billing rows."""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path
from typing import Any

import pandas as pd

from validation.aws_source import validate_aws_source
from validation.common import _money, _write_json
from validation.gcp_source import validate_gcp_source

def run_source_validation(project_root: Path) -> dict[str, Any]:
    """Run both provider validations and write reports without unioning rows."""
    config_dir = project_root / "config"
    aws_dir = project_root / "data" / "synthetic_enterprise_usage" / "aws"
    gcp_dir = project_root / "data" / "synthetic_enterprise_usage" / "gcp"
    output_dir = project_root / "data" / "source_validation"
    output_dir.mkdir(parents=True, exist_ok=True)

    aws_report, aws_exceptions = validate_aws_source(
        config_dir=config_dir,
        source_file=aws_dir / "aws_billing.csv",
        generator_summary_file=aws_dir / "aws_generator_validation_summary.json",
    )
    gcp_report, gcp_exceptions = validate_gcp_source(
        config_dir=config_dir,
        source_file=gcp_dir / "gcp_billing.jsonl",
        generator_summary_file=gcp_dir / "gcp_generator_validation_summary.json",
    )

    _write_json(output_dir / "aws_source_validation.json", aws_report)
    _write_json(output_dir / "gcp_source_validation.json", gcp_report)

    exception_columns = [
        "provider_name",
        "source_record_id",
        "issue_code",
        "severity",
        "usage_date",
        "billing_account_id",
        "account_or_project_id",
        "service_name",
        "data_quality_status",
        "injected_scenario",
        "details",
    ]
    aws_exceptions.reindex(columns=exception_columns).to_csv(
        output_dir / "aws_data_quality_exceptions.csv", index=False
    )
    gcp_exceptions.reindex(columns=exception_columns).to_csv(
        output_dir / "gcp_data_quality_exceptions.csv", index=False
    )

    provider_rows = [
        {
            "provider_name": "AWS",
            "source_format": aws_report["source_format"],
            "row_count": aws_report["control_totals"]["row_count"],
            "primary_cost_total": aws_report["control_totals"]["billed_cost"],
            "nested_credit_total": 0.0,
            "net_cost_total": aws_report["control_totals"]["billed_cost"],
            "duplicated_record_ids": aws_report["exception_counts"]["duplicated_record_ids"],
            "missing_metadata_rows": aws_report["exception_counts"]["missing_tag_rows"],
            "late_arriving_rows": aws_report["exception_counts"]["late_arriving_rows"],
            "invalid_rows": aws_report["exception_counts"]["invalid_rows"],
            "injected_anomaly_rows": aws_report["control_totals"]["injected_anomaly_rows"],
            "overall_status": aws_report["overall_status"],
        },
        {
            "provider_name": "GCP",
            "source_format": gcp_report["source_format"],
            "row_count": gcp_report["control_totals"]["row_count"],
            "primary_cost_total": gcp_report["control_totals"]["cost_before_credits"],
            "nested_credit_total": gcp_report["control_totals"]["credit_amount"],
            "net_cost_total": gcp_report["control_totals"]["net_cost"],
            "duplicated_record_ids": gcp_report["exception_counts"]["duplicated_record_ids"],
            "missing_metadata_rows": gcp_report["exception_counts"]["missing_label_rows"],
            "late_arriving_rows": gcp_report["exception_counts"]["late_arriving_rows"],
            "invalid_rows": gcp_report["exception_counts"]["invalid_rows"],
            "injected_anomaly_rows": gcp_report["control_totals"]["injected_anomaly_rows"],
            "overall_status": gcp_report["overall_status"],
        },
    ]
    provider_controls = pd.DataFrame(provider_rows)
    provider_controls.to_csv(
        output_dir / "source_control_summary.csv", index=False
    )

    combined_control_total = _money(
        Decimal(str(aws_report["control_totals"]["billed_cost"]))
        + Decimal(str(gcp_report["control_totals"]["net_cost"]))
    )
    overall_status = (
        "FAIL"
        if "FAIL" in {aws_report["overall_status"], gcp_report["overall_status"]}
        else "PASS_WITH_EXPECTED_EXCEPTIONS"
    )
    summary = {
        "overall_status": overall_status,
        "billing_rows_were_combined": False,
        "provider_count": 2,
        "provider_statuses": {
            "AWS": aws_report["overall_status"],
            "GCP": gcp_report["overall_status"],
        },
        "provider_row_counts": {
            "AWS": aws_report["control_totals"]["row_count"],
            "GCP": gcp_report["control_totals"]["row_count"],
        },
        "provider_net_cost_controls": {
            "AWS": aws_report["control_totals"]["billed_cost"],
            "GCP": gcp_report["control_totals"]["net_cost"],
        },
        "all_cloud_net_cost_control": combined_control_total,
        "note": (
            "The all-cloud amount is a financial control total only. AWS and GCP "
            "source billing rows remain separate and are not unioned in Milestone 5."
        ),
    }
    _write_json(output_dir / "source_validation_summary.json", summary)
    return summary


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    summary = run_source_validation(project_root)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

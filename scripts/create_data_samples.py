from __future__ import annotations

import csv
from itertools import islice
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SAMPLE_DIR = ROOT / "data" / "samples"

AWS_SOURCE = (
    ROOT
    / "data"
    / "synthetic_enterprise_usage"
    / "aws"
    / "aws_billing.csv"
)
GCP_SOURCE = (
    ROOT
    / "data"
    / "synthetic_enterprise_usage"
    / "gcp"
    / "gcp_billing.jsonl"
)


def create_aws_sample() -> None:
    if not AWS_SOURCE.exists():
        raise FileNotFoundError(
            f"Generate the AWS source file first: {AWS_SOURCE}"
        )

    target = SAMPLE_DIR / "aws_billing_sample.csv"

    with AWS_SOURCE.open(
        "r",
        encoding="utf-8-sig",
        newline="",
    ) as source:
        reader = csv.reader(source)
        rows = list(islice(reader, 101))

    with target.open(
        "w",
        encoding="utf-8",
        newline="",
    ) as destination:
        writer = csv.writer(destination, lineterminator="\n")
        writer.writerows(rows)


def create_gcp_sample() -> None:
    if not GCP_SOURCE.exists():
        raise FileNotFoundError(
            f"Generate the GCP source file first: {GCP_SOURCE}"
        )

    target = SAMPLE_DIR / "gcp_billing_sample.jsonl"

    with GCP_SOURCE.open("r", encoding="utf-8") as source:
        lines = list(islice(source, 100))

    target.write_text(
        "".join(lines),
        encoding="utf-8",
        newline="\n",
    )


def main() -> None:
    SAMPLE_DIR.mkdir(parents=True, exist_ok=True)
    create_aws_sample()
    create_gcp_sample()
    print(f"Created reviewer samples in {SAMPLE_DIR}")


if __name__ == "__main__":
    main()

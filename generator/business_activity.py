
"""Create deterministic retail business activity used by cloud billing generators."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import yaml


BASE_DRIVER_LEVELS = {
    "traffic": 120_000.0,
    "transactions": 12_000.0,
    "queries": 8_000.0,
    "support_requests": 2_400.0,
    "ai_requests": 9_000.0,
}


def _load_config(config_dir: Path) -> tuple[dict[str, Any], pd.DataFrame]:
    with (config_dir / "generator_config.yaml").open("r", encoding="utf-8") as file:
        config = yaml.safe_load(file)

    dimensions = pd.read_csv(config_dir / "business_dimensions.csv", dtype=str)
    return config, dimensions


def generate_business_activity(
    config_dir: Path,
    output_file: Path,
) -> pd.DataFrame:
    """Generate one deterministic business-activity row per workload per day."""
    config, dimensions = _load_config(config_dir)
    seed = int(config["project"]["seed"])
    rng = np.random.default_rng(seed)

    period = config["generation_period"]
    dates = pd.date_range(period["start_date"], period["end_date"], freq="D")

    patterns = config["business_patterns"]
    monthly_growth = float(patterns["monthly_growth_pct"])
    sigma = float(patterns["random_variation_sigma"])
    seasonality = {
        int(month): float(multiplier)
        for month, multiplier in patterns["monthly_seasonality"].items()
    }

    rows: list[dict[str, object]] = []

    for _, dimension in dimensions.iterrows():
        environment = dimension["environment"]
        driver = dimension["business_driver"]
        base_level = BASE_DRIVER_LEVELS[driver]

        workload_scale = 0.35 if environment == "nonprod" else 1.0
        if dimension["workload_id"].startswith("shared-platform"):
            workload_scale *= 1.25

        for date in dates:
            months_elapsed = (
                (date.year - dates[0].year) * 12 + date.month - dates[0].month
            )
            growth_factor = (1.0 + monthly_growth) ** months_elapsed
            seasonal_factor = seasonality[date.month]
            weekend_factor = 1.0

            if date.weekday() >= 5:
                weekend_factor = float(
                    patterns[
                        "production_weekend_factor"
                        if environment == "prod"
                        else "nonproduction_weekend_factor"
                    ]
                )

            noise = float(rng.lognormal(mean=-0.5 * sigma**2, sigma=sigma))
            demand_index = growth_factor * seasonal_factor * weekend_factor * noise
            primary_value = base_level * workload_scale * demand_index

            traffic = primary_value if driver == "traffic" else primary_value * 12.0
            transactions = (
                primary_value if driver == "transactions" else traffic * 0.045
            )
            queries = primary_value if driver == "queries" else traffic * 0.02
            support_requests = (
                primary_value if driver == "support_requests" else traffic * 0.006
            )
            ai_requests = (
                primary_value if driver == "ai_requests" else traffic * 0.015
            )
            api_requests = traffic * 4.0
            active_customers = max(1.0, traffic * 0.14)
            revenue = transactions * 78.0

            rows.append(
                {
                    "activity_date": date.date().isoformat(),
                    "workload_id": dimension["workload_id"],
                    "environment": environment,
                    "business_driver": driver,
                    "demand_index": round(demand_index, 6),
                    "traffic": round(traffic, 2),
                    "transactions": round(transactions, 2),
                    "queries": round(queries, 2),
                    "support_requests": round(support_requests, 2),
                    "ai_requests": round(ai_requests, 2),
                    "api_requests": round(api_requests, 2),
                    "active_customers": round(active_customers, 2),
                    "revenue": round(revenue, 2),
                }
            )

    activity = pd.DataFrame(rows).sort_values(
        ["activity_date", "workload_id"]
    ).reset_index(drop=True)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    activity.to_csv(output_file, index=False)
    return activity

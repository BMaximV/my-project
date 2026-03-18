from __future__ import annotations

import argparse
import json
from pathlib import Path

from app import BASE_METRICS, PARAMETERS, infer_duration_days, detect_title, iter_rows, safe_float


def compute_summary(file_path: Path) -> dict:
    title = detect_title(file_path)
    duration_days = infer_duration_days(title)
    months = duration_days / 30.4375 if duration_days else None

    metric_names = BASE_METRICS + ["Profit / Month", "Trades / Month"]
    sums = {metric: 0.0 for metric in metric_names}
    counts = {metric: 0 for metric in metric_names}
    row_count = 0

    for raw_row in iter_rows(file_path):
        row_count += 1
        for metric in BASE_METRICS:
            value = safe_float(raw_row.get(metric))
            if value is None:
                continue
            sums[metric] += value
            counts[metric] += 1

        profit = safe_float(raw_row.get("Profit"))
        trades = safe_float(raw_row.get("Trades"))
        if months and profit is not None:
            sums["Profit / Month"] += profit / months
            counts["Profit / Month"] += 1
        if months and trades is not None:
            sums["Trades / Month"] += trades / months
            counts["Trades / Month"] += 1

    averages = {metric: (sums[metric] / counts[metric] if counts[metric] else None) for metric in metric_names}
    return {
        "title": title,
        "duration_days": duration_days,
        "row_count": row_count,
        "averages": averages,
    }


def compute_slice(file_path: Path, parameter: str, target: float) -> dict:
    if parameter not in PARAMETERS:
        raise ValueError(f"Unknown parameter: {parameter}")

    metric_names = BASE_METRICS
    sums = {metric: 0.0 for metric in metric_names}
    counts = {metric: 0 for metric in metric_names}
    matched_rows = 0

    for raw_row in iter_rows(file_path):
        param_value = safe_float(raw_row.get(parameter))
        if param_value is None or param_value != target:
            continue

        matched_rows += 1
        for metric in metric_names:
            value = safe_float(raw_row.get(metric))
            if value is None:
                continue
            sums[metric] += value
            counts[metric] += 1

    averages = {metric: (sums[metric] / counts[metric] if counts[metric] else None) for metric in metric_names}
    return {
        "parameter": parameter,
        "value": target,
        "matched_rows": matched_rows,
        "averages": averages,
    }


def sample_rows(file_path: Path, limit: int) -> list[dict]:
    rows = []
    for index, raw_row in enumerate(iter_rows(file_path), start=1):
        row = {key: raw_row.get(key) for key in ["Pass", *BASE_METRICS, *PARAMETERS]}
        rows.append(row)
        if index >= limit:
            break
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify MT5 XML metrics against Excel.")
    parser.add_argument("xml_file", type=Path)
    parser.add_argument("--parameter", type=str, help="Parameter name for exact slice check.")
    parser.add_argument("--value", type=float, help="Exact parameter value for slice check.")
    parser.add_argument("--sample", type=int, default=0, help="Dump first N parsed rows.")
    parser.add_argument("--no-summary", action="store_true", help="Skip full-file summary to speed up targeted checks.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON.")
    args = parser.parse_args()

    payload: dict[str, object] = {}
    if not args.no_summary:
        payload["summary"] = compute_summary(args.xml_file)
    if args.parameter and args.value is not None:
        payload["slice"] = compute_slice(args.xml_file, args.parameter, args.value)
    if args.sample > 0:
        payload["sample_rows"] = sample_rows(args.xml_file, args.sample)

    if args.pretty:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()

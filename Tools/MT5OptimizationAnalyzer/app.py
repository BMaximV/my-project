from __future__ import annotations

import heapq
import json
import math
import re
import hashlib
from dataclasses import dataclass
from datetime import date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from xml.etree.ElementTree import iterparse


ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
CACHE_DIR = ROOT / "cache"
HOST = "127.0.0.1"
PORT = 8765
XML_NS = "{urn:schemas-microsoft-com:office:spreadsheet}"
INDEX_FILE = ROOT / "index.html"
TITLE_PERIOD_RE = re.compile(r"(\d{4}\.\d{2}\.\d{2})-(\d{4}\.\d{2}\.\d{2})")
CACHE_VERSION = 2

BASE_METRICS = [
    "Result",
    "Profit",
    "Expected Payoff",
    "Profit Factor",
    "Recovery Factor",
    "Sharpe Ratio",
    "Custom",
    "Equity DD %",
    "Trades",
]

PARAMETERS = [
    "MultiplyLot",
    "Distance",
    "Trail_Start",
    "Trail_Distance",
    "Max_Trades",
]

SCORE_METRICS = [
    "Profit",
    "Profit Factor",
    "Sharpe Ratio",
    "Recovery Factor",
    "Equity DD %",
    "Trades",
]


def make_cache_key(file_path: Path) -> str:
    stat = file_path.stat()
    raw = f"{file_path.resolve()}|{stat.st_size}|{stat.st_mtime_ns}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def cache_path_for(file_path: Path) -> Path:
    return CACHE_DIR / f"{make_cache_key(file_path)}.json"


def safe_float(value: str | None) -> float | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    try:
        return float(text.replace(",", "."))
    except ValueError:
        return None


def local_name(tag: str) -> str:
    return tag.split("}", 1)[-1]


def detect_title(file_path: Path) -> str | None:
    with file_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for _ in range(80):
            line = handle.readline()
            if not line:
                break
            if "<Title>" in line and "</Title>" in line:
                return re.sub(r".*<Title>|</Title>.*", "", line).strip()
    return None


def infer_duration_days(title: str | None) -> int | None:
    if not title:
        return None

    match = TITLE_PERIOD_RE.search(title)
    if not match:
        return None

    start = date.fromisoformat(match.group(1).replace(".", "-"))
    end = date.fromisoformat(match.group(2).replace(".", "-"))
    return (end - start).days + 1


@dataclass
class RunningStat:
    count: int = 0
    mean: float = 0.0
    m2: float = 0.0

    def update(self, value: float | None) -> None:
        if value is None or not math.isfinite(value):
            return
        self.count += 1
        delta = value - self.mean
        self.mean += delta / self.count
        delta2 = value - self.mean
        self.m2 += delta * delta2

    @property
    def stdev(self) -> float:
        if self.count < 2:
            return 1.0
        variance = self.m2 / self.count
        return math.sqrt(variance) or 1.0


def iter_rows(file_path: Path):
    headers: list[str] | None = None
    index_attr = f"{XML_NS}Index"

    for _, elem in iterparse(file_path, events=("end",)):
        if local_name(elem.tag) != "Row":
            continue

        values: list[str | None] = []
        current_index = 0
        for cell in list(elem):
            if local_name(cell.tag) != "Cell":
                continue
            explicit_index = cell.attrib.get(index_attr)
            if explicit_index:
                current_index = max(current_index, int(explicit_index) - 1)

            cell_value = None
            for child in list(cell):
                if local_name(child.tag) == "Data":
                    cell_value = child.text
                    break

            while len(values) <= current_index:
                values.append(None)
            values[current_index] = cell_value
            current_index += 1

        elem.clear()
        normalized = [(value or "").strip() for value in values]
        if not any(normalized):
            continue

        if headers is None:
            headers = normalized
            continue

        row = {headers[i]: normalized[i] if i < len(normalized) else None for i in range(len(headers))}
        yield row


def compute_score(row: dict[str, float | int | None], stats: dict[str, RunningStat]) -> float:
    def z(metric: str) -> float:
        value = row.get(metric)
        if value is None or not math.isfinite(float(value)):
            return 0.0
        stat = stats[metric]
        return (float(value) - stat.mean) / stat.stdev

    return (
        z("Profit") * 0.30
        + z("Profit Factor") * 0.20
        + z("Sharpe Ratio") * 0.18
        + z("Recovery Factor") * 0.17
        + z("Trades") * 0.10
        - z("Equity DD %") * 0.25
    )


def compute_best_ranges(parameter_rows: list[dict], top_n: int = 5) -> list[dict]:
    if len(parameter_rows) < 2:
        return []

    max_window = min(6, len(parameter_rows))
    candidates: list[dict] = []

    for window in range(2, max_window + 1):
        for start in range(0, len(parameter_rows) - window + 1):
            segment = parameter_rows[start:start + window]
            score_values = [row["avg"].get("Robustness Score") for row in segment]
            filtered_scores = [float(value) for value in score_values if value is not None and math.isfinite(float(value))]
            if not filtered_scores:
                continue

            total_runs = sum(int(row["count"]) for row in segment)

            def weighted_average(metric: str) -> float | None:
                weighted_sum = 0.0
                used_runs = 0
                for row in segment:
                    value = row["avg"].get(metric)
                    count = int(row["count"])
                    if value is None or not math.isfinite(float(value)):
                        continue
                    weighted_sum += float(value) * count
                    used_runs += count
                return weighted_sum / used_runs if used_runs else None

            avg_score = weighted_average("Robustness Score")
            avg_profit = weighted_average("Profit")
            avg_dd = weighted_average("Equity DD %")
            avg_pf = weighted_average("Profit Factor")
            stability = min(row["count"] for row in segment)

            candidates.append({
                "start": float(segment[0]["value"]),
                "end": float(segment[-1]["value"]),
                "points": len(segment),
                "runs": total_runs,
                "stability_floor": stability,
                "avg_score": avg_score,
                "avg_profit": avg_profit,
                "avg_dd": avg_dd,
                "avg_pf": avg_pf,
                "score_rank": (
                    (avg_score if avg_score is not None else float("-inf")),
                    math.log10(max(total_runs, 1)),
                    -(avg_dd if avg_dd is not None else float("inf")),
                ),
            })

    candidates.sort(key=lambda item: item["score_rank"], reverse=True)

    chosen: list[dict] = []
    covered_ranges: list[tuple[float, float]] = []
    for candidate in candidates:
        overlaps = any(
            not (candidate["end"] < existing_start or candidate["start"] > existing_end)
            for existing_start, existing_end in covered_ranges
        )
        if overlaps and len(chosen) >= top_n:
            continue
        chosen.append({
            key: value for key, value in candidate.items() if key != "score_rank"
        })
        covered_ranges.append((candidate["start"], candidate["end"]))
        if len(chosen) >= top_n:
            break

    return chosen


def analyze_file(file_path: Path | str) -> dict:
    file_path = Path(file_path)
    title = detect_title(file_path)
    duration_days = infer_duration_days(title)
    months = duration_days / 30.4375 if duration_days else None

    stats = {metric: RunningStat() for metric in SCORE_METRICS}
    row_count = 0

    for raw_row in iter_rows(file_path):
        row_count += 1
        for metric in SCORE_METRICS:
            stats[metric].update(safe_float(raw_row.get(metric)))

    metrics = BASE_METRICS + ["Profit / Month", "Trades / Month", "Robustness Score"]
    parameter_stats: dict[str, dict[float, dict]] = {parameter: {} for parameter in PARAMETERS}
    global_sums = {metric: 0.0 for metric in metrics if metric not in {"Robustness Score"}}
    global_counts = {metric: 0 for metric in metrics}
    top_heap: list[tuple[float, int, dict]] = []

    for raw_row in iter_rows(file_path):
        row: dict[str, float | int | None] = {}
        for key in ["Pass", *BASE_METRICS, *PARAMETERS]:
            numeric = safe_float(raw_row.get(key))
            row[key] = int(numeric) if key in {"Pass", "Trades", "Distance", "Trail_Start", "Trail_Distance", "Max_Trades"} and numeric is not None else numeric

        if months:
            row["Profit / Month"] = (row["Profit"] or 0.0) / months if row["Profit"] is not None else None
            row["Trades / Month"] = (row["Trades"] or 0.0) / months if row["Trades"] is not None else None
        else:
            row["Profit / Month"] = None
            row["Trades / Month"] = None

        row["Robustness Score"] = compute_score(row, stats)

        for metric in metrics:
            value = row.get(metric)
            if value is not None and math.isfinite(float(value)):
                global_sums.setdefault(metric, 0.0)
                global_counts[metric] = global_counts.get(metric, 0) + 1
                global_sums[metric] = global_sums.get(metric, 0.0) + float(value)

        snapshot = {key: row.get(key) for key in ["Pass", *BASE_METRICS, *PARAMETERS, "Profit / Month", "Trades / Month", "Robustness Score"]}
        entry = (float(row["Robustness Score"]), int(row["Pass"] or 0), snapshot)
        if len(top_heap) < 100:
            heapq.heappush(top_heap, entry)
        else:
            heapq.heappushpop(top_heap, entry)

        for parameter in PARAMETERS:
            param_value = row.get(parameter)
            if param_value is None:
                continue
            bucket = parameter_stats[parameter].setdefault(float(param_value), {"count": 0, "sums": {metric: 0.0 for metric in metrics}, "counts": {metric: 0 for metric in metrics}})
            bucket["count"] += 1
            for metric in metrics:
                metric_value = row.get(metric)
                if metric_value is None or not math.isfinite(float(metric_value)):
                    continue
                bucket["sums"][metric] += float(metric_value)
                bucket["counts"][metric] += 1

    parameter_payload = {}
    best_ranges_payload = {}
    for parameter, buckets in parameter_stats.items():
        rows = []
        for value, bucket in sorted(buckets.items(), key=lambda item: item[0]):
            averages = {}
            for metric in metrics:
                count = bucket["counts"][metric]
                averages[metric] = bucket["sums"][metric] / count if count else None
            rows.append({"value": value, "count": bucket["count"], "avg": averages})
        parameter_payload[parameter] = rows
        best_ranges_payload[parameter] = compute_best_ranges(rows)

    top_passes = [item[2] for item in sorted(top_heap, key=lambda item: (-item[0], -item[1]))]
    summary = {metric: (global_sums[metric] / global_counts[metric] if global_counts.get(metric) else None) for metric in metrics}

    return {
        "cache_version": CACHE_VERSION,
        "file_name": file_path.name,
        "file_size_mb": round(file_path.stat().st_size / (1024 * 1024), 2),
        "title": title,
        "duration_days": duration_days,
        "row_count": row_count,
        "metrics": metrics,
        "parameters": PARAMETERS,
        "summary": summary,
        "top_passes": top_passes,
        "parameter_stats": parameter_payload,
        "best_ranges": best_ranges_payload,
    }


def load_cached_analysis(file_path: Path) -> dict | None:
    cache_file = cache_path_for(file_path)
    if not cache_file.exists():
        return None

    with cache_file.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    if payload.get("cache_version") != CACHE_VERSION:
        return None

    payload["cache_hit"] = True
    return payload


def store_cached_analysis(file_path: Path, payload: dict) -> dict:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = cache_path_for(file_path)
    serializable = dict(payload)
    serializable["cache_hit"] = False

    with cache_file.open("w", encoding="utf-8") as handle:
        json.dump(serializable, handle, ensure_ascii=False)

    return serializable


def get_analysis(file_path: Path) -> dict:
    cached = load_cached_analysis(file_path)
    if cached is not None:
        return cached

    fresh = analyze_file(file_path)
    return store_cached_analysis(file_path, fresh)


def list_xml_files() -> list[dict]:
    items = []
    for path in sorted(DATA_DIR.rglob("*.xml")):
        relative = path.relative_to(ROOT).as_posix()
        items.append({
            "path": relative,
            "name": path.name,
            "size_mb": round(path.stat().st_size / (1024 * 1024), 2),
        })
    return items


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/index.html"}:
            content = INDEX_FILE.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        if parsed.path == "/api/files":
            self.send_json({"files": list_xml_files()})
            return

        if parsed.path == "/api/analyze":
            query = parse_qs(parsed.query)
            relative = query.get("file", [None])[0]
            if not relative:
                self.send_json({"error": "File is required."}, status=400)
                return

            file_path = (ROOT / relative).resolve()
            if DATA_DIR.resolve() not in file_path.parents or not file_path.exists():
                self.send_json({"error": "File is outside data directory or missing."}, status=400)
                return

            try:
                payload = get_analysis(file_path)
            except Exception as exc:
                self.send_json({"error": f"Analysis failed: {exc}"}, status=500)
                return

            self.send_json(payload)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:
        return

    def send_json(self, payload: dict, status: int = 200) -> None:
        content = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    url = f"http://{HOST}:{PORT}/"
    print(f"MT5 Optimization Analyzer: {url}")
    print(f"Open in browser: {url}")
    server.serve_forever()


if __name__ == "__main__":
    main()

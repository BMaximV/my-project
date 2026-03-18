from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import threading
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
CACHE_VERSION = 5
MEMORY_CACHE: dict[str, dict] = {}

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

METRIC_TO_COLUMN = {
    "Pass": "pass_id",
    "Result": "result",
    "Profit": "profit",
    "Expected Payoff": "expected_payoff",
    "Profit Factor": "profit_factor",
    "Recovery Factor": "recovery_factor",
    "Sharpe Ratio": "sharpe_ratio",
    "Custom": "custom",
    "Equity DD %": "equity_dd",
    "Trades": "trades",
    "MultiplyLot": "multiply_lot",
    "Distance": "distance",
    "Trail_Start": "trail_start",
    "Trail_Distance": "trail_distance",
    "Max_Trades": "max_trades",
    "Profit / Month": "profit_per_month",
    "Trades / Month": "trades_per_month",
    "Robustness Score": "robustness_score",
}


def make_cache_key(file_path: Path) -> str:
    stat = file_path.stat()
    raw = f"{file_path.resolve()}|{stat.st_size}|{stat.st_mtime_ns}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def db_path_for(file_path: Path) -> Path:
    return CACHE_DIR / f"{make_cache_key(file_path)}.sqlite3"


def meta_path_for(file_path: Path) -> Path:
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

        yield {headers[i]: normalized[i] if i < len(normalized) else None for i in range(len(headers))}


def is_allowed_row(raw_row: dict[str, str | None]) -> bool:
    trail_start = safe_float(raw_row.get("Trail_Start"))
    trail_distance = safe_float(raw_row.get("Trail_Distance"))
    if trail_start is None or trail_distance is None:
        return True
    return trail_start <= trail_distance


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

    candidates: list[dict] = []
    max_window = min(6, len(parameter_rows))
    for window in range(2, max_window + 1):
        for start in range(0, len(parameter_rows) - window + 1):
            segment = parameter_rows[start:start + window]
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
            if avg_score is None:
                continue

            avg_profit = weighted_average("Profit")
            avg_dd = weighted_average("Equity DD %")
            avg_pf = weighted_average("Profit Factor")
            stability_floor = min(int(row["count"]) for row in segment)
            candidates.append({
                "start": float(segment[0]["value"]),
                "end": float(segment[-1]["value"]),
                "points": len(segment),
                "runs": total_runs,
                "stability_floor": stability_floor,
                "avg_score": avg_score,
                "avg_profit": avg_profit,
                "avg_dd": avg_dd,
                "avg_pf": avg_pf,
                "score_rank": (avg_score, math.log10(max(total_runs, 1)), -(avg_dd if avg_dd is not None else float("inf"))),
            })

    candidates.sort(key=lambda item: item["score_rank"], reverse=True)
    return [{key: value for key, value in candidate.items() if key != "score_rank"} for candidate in candidates[:top_n]]


def compute_region_score(summary: dict, row_count: int, baseline_count: int) -> float:
    avg_score = summary.get("Robustness Score")
    avg_profit = summary.get("Profit")
    avg_dd = summary.get("Equity DD %")
    avg_pf = summary.get("Profit Factor")
    if avg_score is None or avg_profit is None or avg_dd is None or avg_pf is None or row_count <= 0:
        return float("-inf")

    coverage = row_count / baseline_count if baseline_count else 0.0
    support_bonus = math.log10(max(row_count, 10))
    return (
        float(avg_score) * 1.8
        + math.tanh(float(avg_profit) / 500.0) * 0.9
        + math.tanh(float(avg_pf) - 1.0) * 0.6
        - max(float(avg_dd), 0.0) / 25.0
        + coverage * 1.2
        + support_bonus * 0.15
    )


def load_metadata(file_path: Path) -> dict | None:
    meta_path = meta_path_for(file_path)
    db_path = db_path_for(file_path)
    if not meta_path.exists() or not db_path.exists():
        return None
    payload = json.loads(meta_path.read_text(encoding="utf-8"))
    if payload.get("cache_version") != CACHE_VERSION:
        return None
    payload["cache_hit"] = True
    return payload


def save_metadata(file_path: Path, payload: dict) -> dict:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    meta_path = meta_path_for(file_path)
    serializable = dict(payload)
    serializable["cache_hit"] = False
    meta_path.write_text(json.dumps(serializable, ensure_ascii=False), encoding="utf-8")
    return serializable


def build_cache(file_path: Path) -> dict:
    title = detect_title(file_path)
    duration_days = infer_duration_days(title)
    months = duration_days / 30.4375 if duration_days else None

    stats = {metric: RunningStat() for metric in SCORE_METRICS}
    source_row_count = 0
    included_row_count = 0
    excluded_row_count = 0

    for raw_row in iter_rows(file_path):
        source_row_count += 1
        if not is_allowed_row(raw_row):
            excluded_row_count += 1
            continue
        included_row_count += 1
        for metric in SCORE_METRICS:
            stats[metric].update(safe_float(raw_row.get(metric)))

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    db_path = db_path_for(file_path)
    if db_path.exists():
        db_path.unlink()

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("PRAGMA temp_store=MEMORY")
    conn.execute(
        """
        CREATE TABLE runs (
            pass_id INTEGER,
            result REAL,
            profit REAL,
            expected_payoff REAL,
            profit_factor REAL,
            recovery_factor REAL,
            sharpe_ratio REAL,
            custom REAL,
            equity_dd REAL,
            trades REAL,
            multiply_lot REAL,
            distance REAL,
            trail_start REAL,
            trail_distance REAL,
            max_trades REAL,
            profit_per_month REAL,
            trades_per_month REAL,
            robustness_score REAL
        )
        """
    )

    parameter_bounds = {parameter: {"min": None, "max": None} for parameter in PARAMETERS}
    parameter_values = {parameter: set() for parameter in PARAMETERS}
    batch: list[tuple] = []

    for raw_row in iter_rows(file_path):
        if not is_allowed_row(raw_row):
            continue

        row: dict[str, float | int | None] = {}
        for key in ["Pass", *BASE_METRICS, *PARAMETERS]:
            numeric = safe_float(raw_row.get(key))
            row[key] = int(numeric) if key in {"Pass", "Trades", "Distance", "Trail_Start", "Trail_Distance", "Max_Trades"} and numeric is not None else numeric

        row["Profit / Month"] = (row["Profit"] or 0.0) / months if months and row["Profit"] is not None else None
        row["Trades / Month"] = (row["Trades"] or 0.0) / months if months and row["Trades"] is not None else None
        row["Robustness Score"] = compute_score(row, stats)

        for parameter in PARAMETERS:
            value = row.get(parameter)
            if value is None:
                continue
            bounds = parameter_bounds[parameter]
            numeric = float(value)
            bounds["min"] = numeric if bounds["min"] is None else min(bounds["min"], numeric)
            bounds["max"] = numeric if bounds["max"] is None else max(bounds["max"], numeric)
            parameter_values[parameter].add(numeric)

        batch.append((
            row.get("Pass"),
            row.get("Result"),
            row.get("Profit"),
            row.get("Expected Payoff"),
            row.get("Profit Factor"),
            row.get("Recovery Factor"),
            row.get("Sharpe Ratio"),
            row.get("Custom"),
            row.get("Equity DD %"),
            row.get("Trades"),
            row.get("MultiplyLot"),
            row.get("Distance"),
            row.get("Trail_Start"),
            row.get("Trail_Distance"),
            row.get("Max_Trades"),
            row.get("Profit / Month"),
            row.get("Trades / Month"),
            row.get("Robustness Score"),
        ))

        if len(batch) >= 5000:
            conn.executemany("INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
            conn.commit()
            batch.clear()

    if batch:
        conn.executemany("INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
        conn.commit()

    for index_sql in [
        "CREATE INDEX idx_runs_pass ON runs(pass_id)",
        "CREATE INDEX idx_runs_score ON runs(robustness_score DESC)",
        "CREATE INDEX idx_runs_multiply_lot ON runs(multiply_lot)",
        "CREATE INDEX idx_runs_distance ON runs(distance)",
        "CREATE INDEX idx_runs_trail_start ON runs(trail_start)",
        "CREATE INDEX idx_runs_trail_distance ON runs(trail_distance)",
        "CREATE INDEX idx_runs_max_trades ON runs(max_trades)",
    ]:
        conn.execute(index_sql)
    conn.commit()
    conn.close()

    payload = {
        "cache_version": CACHE_VERSION,
        "file_name": file_path.name,
        "file_size_mb": round(file_path.stat().st_size / (1024 * 1024), 2),
        "title": title,
        "duration_days": duration_days,
        "source_row_count": source_row_count,
        "row_count": included_row_count,
        "excluded_row_count": excluded_row_count,
        "metrics": BASE_METRICS + ["Profit / Month", "Trades / Month", "Robustness Score"],
        "parameters": PARAMETERS,
        "parameter_bounds": parameter_bounds,
        "parameter_values": {parameter: sorted(values) for parameter, values in parameter_values.items()},
    }
    return save_metadata(file_path, payload)


def ensure_cache(file_path: Path) -> dict:
    metadata = load_metadata(file_path)
    if metadata is not None:
        return metadata
    return build_cache(file_path)


def get_memory_connection(file_path: Path) -> sqlite3.Connection:
    cache_key = make_cache_key(file_path)
    cached = MEMORY_CACHE.get(cache_key)
    if cached is not None:
        return cached["conn"]

    disk_conn = sqlite3.connect(db_path_for(file_path))
    memory_conn = sqlite3.connect(":memory:", check_same_thread=False)
    disk_conn.backup(memory_conn)
    disk_conn.close()
    memory_conn.row_factory = sqlite3.Row
    MEMORY_CACHE[cache_key] = {"conn": memory_conn, "lock": threading.Lock()}
    return memory_conn


def get_memory_lock(file_path: Path) -> threading.Lock:
    cache_key = make_cache_key(file_path)
    if cache_key not in MEMORY_CACHE:
        get_memory_connection(file_path)
    return MEMORY_CACHE[cache_key]["lock"]


def normalize_filters(metadata: dict, query: dict[str, list[str]]) -> dict[str, dict[str, float]]:
    filters = {}
    for parameter in PARAMETERS:
        bounds = metadata["parameter_bounds"][parameter]
        min_value = float(query.get(f"min_{parameter}", [bounds["min"]])[0])
        max_value = float(query.get(f"max_{parameter}", [bounds["max"]])[0])
        if min_value > max_value:
            min_value, max_value = max_value, min_value
        filters[parameter] = {"min": min_value, "max": max_value}
    return filters


def build_where_clause(filters: dict[str, dict[str, float]]) -> tuple[str, list[float]]:
    clauses = []
    params: list[float] = []
    for parameter in PARAMETERS:
        column = METRIC_TO_COLUMN[parameter]
        clauses.append(f"{column} BETWEEN ? AND ?")
        params.append(filters[parameter]["min"])
        params.append(filters[parameter]["max"])
    return " AND ".join(clauses), params


def filter_signature(filters: dict[str, dict[str, float]]) -> tuple:
    return tuple((parameter, filters[parameter]["min"], filters[parameter]["max"]) for parameter in PARAMETERS)


def fetch_summary(conn: sqlite3.Connection, where_clause: str, params: list[float], metrics: list[str]) -> tuple[int, dict]:
    select_parts = ["COUNT(*) AS row_count"]
    for metric in metrics:
        select_parts.append(f"AVG({METRIC_TO_COLUMN[metric]}) AS [{metric}]")
    sql = f"SELECT {', '.join(select_parts)} FROM runs WHERE {where_clause}"
    row = conn.execute(sql, params).fetchone()
    row_count = int(row["row_count"])
    summary = {metric: row[metric] for metric in metrics}
    return row_count, summary


def evaluate_region(conn: sqlite3.Connection, metadata: dict, filters: dict[str, dict[str, float]]) -> dict | None:
    where_clause, params = build_where_clause(filters)
    row_count, summary = fetch_summary(conn, where_clause, params, metadata["metrics"])
    minimum_runs = max(1000, int(metadata["row_count"] * 0.01))
    if row_count < minimum_runs:
        return None

    score = compute_region_score(summary, row_count, metadata["row_count"])
    if not math.isfinite(score):
        return None

    return {
        "filters": {parameter: {"min": filters[parameter]["min"], "max": filters[parameter]["max"]} for parameter in PARAMETERS},
        "row_count": row_count,
        "coverage": row_count / metadata["row_count"] if metadata["row_count"] else 0.0,
        "summary": {
            "Profit": summary.get("Profit"),
            "Profit Factor": summary.get("Profit Factor"),
            "Equity DD %": summary.get("Equity DD %"),
            "Robustness Score": summary.get("Robustness Score"),
        },
        "region_score": score,
    }


def auto_search_regions(file_path: Path, query: dict[str, list[str]]) -> dict:
    metadata = ensure_cache(file_path)
    base_filters = normalize_filters(metadata, query)
    beam_width = 5
    max_regions = 8
    max_depth = 3
    conn = get_memory_connection(file_path)
    lock = get_memory_lock(file_path)

    with lock:
        seed = evaluate_region(conn, metadata, base_filters)
        if seed is None:
            return {
                "regions": [],
                "base_filters": base_filters,
                "searched_from_count": 0,
            }

        frontier = [seed]
        best: list[dict] = [seed]
        seen = {filter_signature(seed["filters"])}

        for _ in range(max_depth):
            candidates: list[dict] = []
            for region in frontier:
                filters = region["filters"]
                for parameter in PARAMETERS:
                    values = metadata["parameter_values"][parameter]
                    current_min = filters[parameter]["min"]
                    current_max = filters[parameter]["max"]
                    try:
                        min_index = values.index(current_min)
                        max_index = values.index(current_max)
                    except ValueError:
                        continue

                    if min_index < max_index:
                        tightened = {name: {"min": value["min"], "max": value["max"]} for name, value in filters.items()}
                        tightened[parameter]["min"] = values[min_index + 1]
                        signature = filter_signature(tightened)
                        if signature not in seen:
                            seen.add(signature)
                            candidate = evaluate_region(conn, metadata, tightened)
                            if candidate is not None:
                                candidates.append(candidate)

                        tightened = {name: {"min": value["min"], "max": value["max"]} for name, value in filters.items()}
                        tightened[parameter]["max"] = values[max_index - 1]
                        signature = filter_signature(tightened)
                        if signature not in seen:
                            seen.add(signature)
                            candidate = evaluate_region(conn, metadata, tightened)
                            if candidate is not None:
                                candidates.append(candidate)

            candidates.sort(key=lambda item: item["region_score"], reverse=True)
            frontier = candidates[:beam_width]
            if not frontier:
                break
            best.extend(frontier)

    best.sort(key=lambda item: item["region_score"], reverse=True)
    unique: list[dict] = []
    used = set()
    for region in best:
        signature = filter_signature(region["filters"])
        if signature in used:
            continue
        used.add(signature)
        unique.append(region)
        if len(unique) >= max_regions:
            break

    return {
        "regions": unique,
        "base_filters": base_filters,
        "searched_from_count": seed["row_count"],
    }


def fetch_top_passes(conn: sqlite3.Connection, where_clause: str, params: list[float]) -> list[dict]:
    sql = f"""
        SELECT pass_id, result, profit, expected_payoff, profit_factor, recovery_factor, sharpe_ratio,
               custom, equity_dd, trades, multiply_lot, distance, trail_start, trail_distance,
               max_trades, profit_per_month, trades_per_month, robustness_score
        FROM runs
        WHERE {where_clause}
        ORDER BY robustness_score DESC, pass_id DESC
        LIMIT 100
    """
    rows = conn.execute(sql, params).fetchall()
    payload = []
    for row in rows:
        payload.append({
            "Pass": row["pass_id"],
            "Result": row["result"],
            "Profit": row["profit"],
            "Expected Payoff": row["expected_payoff"],
            "Profit Factor": row["profit_factor"],
            "Recovery Factor": row["recovery_factor"],
            "Sharpe Ratio": row["sharpe_ratio"],
            "Custom": row["custom"],
            "Equity DD %": row["equity_dd"],
            "Trades": row["trades"],
            "MultiplyLot": row["multiply_lot"],
            "Distance": row["distance"],
            "Trail_Start": row["trail_start"],
            "Trail_Distance": row["trail_distance"],
            "Max_Trades": row["max_trades"],
            "Profit / Month": row["profit_per_month"],
            "Trades / Month": row["trades_per_month"],
            "Robustness Score": row["robustness_score"],
        })
    return payload


def fetch_parameter_stats(conn: sqlite3.Connection, where_clause: str, params: list[float], metrics: list[str]) -> tuple[dict, dict]:
    parameter_stats = {}
    best_ranges = {}
    for parameter in PARAMETERS:
        column = METRIC_TO_COLUMN[parameter]
        select_parts = [f"{column} AS value", "COUNT(*) AS count"]
        for metric in metrics:
            select_parts.append(f"AVG({METRIC_TO_COLUMN[metric]}) AS [{metric}]")
        sql = f"""
            SELECT {', '.join(select_parts)}
            FROM runs
            WHERE {where_clause}
            GROUP BY {column}
            ORDER BY {column}
        """
        rows = conn.execute(sql, params).fetchall()
        parameter_rows = []
        for row in rows:
            averages = {metric: row[metric] for metric in metrics}
            parameter_rows.append({"value": row["value"], "count": row["count"], "avg": averages})
        parameter_stats[parameter] = parameter_rows
        best_ranges[parameter] = compute_best_ranges(parameter_rows)
    return parameter_stats, best_ranges


def query_analysis(file_path: Path, query: dict[str, list[str]]) -> dict:
    metadata = ensure_cache(file_path)
    filters = normalize_filters(metadata, query)
    where_clause, params = build_where_clause(filters)
    metrics = metadata["metrics"]
    preview_only = query.get("preview", ["0"])[0] == "1"
    conn = get_memory_connection(file_path)
    lock = get_memory_lock(file_path)

    with lock:
        row_count, summary = fetch_summary(conn, where_clause, params, metrics)
        top_passes = [] if preview_only else fetch_top_passes(conn, where_clause, params)
        parameter_stats, best_ranges = ({}, {}) if preview_only else fetch_parameter_stats(conn, where_clause, params, metrics)

    payload = dict(metadata)
    payload.update({
        "row_count": row_count,
        "filtered_out_count": metadata["row_count"] - row_count,
        "summary": summary,
        "top_passes": top_passes,
        "parameter_stats": parameter_stats,
        "best_ranges": best_ranges,
        "applied_filters": filters,
        "preview_only": preview_only,
    })
    payload["cache_hit"] = True
    return payload


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
                payload = query_analysis(file_path, query)
            except Exception as exc:
                self.send_json({"error": f"Analysis failed: {exc}"}, status=500)
                return

            self.send_json(payload)
            return

        if parsed.path == "/api/auto_search":
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
                payload = auto_search_regions(file_path, query)
            except Exception as exc:
                self.send_json({"error": f"Auto search failed: {exc}"}, status=500)
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

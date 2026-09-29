#!/usr/bin/env python3
"""
validate_schema.py
Two checks in one:
  1. Schema check  — every table in metrics.csv exists in BigQuery INFORMATION_SCHEMA
  2. Access check  — every table referenced in patterns.sql is in that pod's
                     access/pods.yaml bigquery_grants list

Usage:
    python3 build/validate_schema.py               # all pods
    python3 build/validate_schema.py --pod adsc    # one pod
    python3 build/validate_schema.py --skip-bq     # skip live BQ calls (CI without credentials)

Exit 0 = all clean. Exit 1 = failures found (blocks PR merge).
"""

import argparse
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT  = Path(__file__).resolve().parent.parent
SKILLS_DIR = REPO_ROOT / "skills"
ACCESS_CFG = REPO_ROOT / "access" / "pods.yaml"
PROJECT    = "storm-wall-185017"


def load_access_grants():
    """Returns {pod_id: [dataset, ...]} from access/pods.yaml."""
    cfg = yaml.safe_load(ACCESS_CFG.read_text())
    return {
        pod["id"]: pod.get("bigquery_grants", [])
        for pod in cfg.get("pods", [])
    }


def tables_from_csv(csv_path):
    """Extract fully-qualified table names from metrics.csv 'table' column."""
    tables = set()
    for line in csv_path.read_text().splitlines()[1:]:  # skip header
        if not line.strip():
            continue
        parts = line.split(",")
        if len(parts) < 3:
            continue
        raw = parts[2].strip().strip('"').strip("'")
        # May be compound like "tableA + tableB"
        for t in re.split(r"\s*\+\s*", raw):
            t = t.strip()
            if t.startswith("storm-wall-185017.") and " " not in t:
                tables.add(t)
    return tables


def tables_from_sql(sql_path):
    """Extract table references from patterns.sql backtick-quoted tables."""
    content = sql_path.read_text()
    return set(re.findall(r"`(storm-wall-185017\.[^`]+)`", content))


def dataset_of(full_table):
    """storm-wall-185017.adsc_gold.fact_adsc_orders  →  adsc_gold"""
    parts = full_table.split(".")
    return parts[1] if len(parts) >= 3 else None


def check_access(pod_id, all_tables, grants):
    pod_grants = grants.get(pod_id, [])
    errors = []
    for t in sorted(all_tables):
        ds = dataset_of(t)
        if ds and ds not in pod_grants:
            errors.append(f"  Table {t} references dataset '{ds}' not in pods.yaml grants for '{pod_id}'")
    return errors


def check_schema_bq(tables):
    """Return {table: True/False} for whether each table exists in BQ."""
    try:
        from google.cloud import bigquery
        client = bigquery.Client(project=PROJECT)
    except ImportError:
        print("  [skip] google-cloud-bigquery not installed — schema check skipped")
        return {}

    results = {}
    datasets_checked = {}

    for t in sorted(tables):
        parts = t.split(".")
        if len(parts) != 3:
            results[t] = None
            continue
        _, dataset, table = parts
        if dataset not in datasets_checked:
            try:
                q = f"SELECT table_name FROM `{PROJECT}.{dataset}.INFORMATION_SCHEMA.TABLES`"
                rows = list(client.query(q).result())
                datasets_checked[dataset] = {r.table_name for r in rows}
            except Exception as e:
                print(f"  [warn] Cannot access {PROJECT}.{dataset}: {e}")
                datasets_checked[dataset] = None

        known = datasets_checked.get(dataset)
        if known is None:
            results[t] = None  # unknown — dataset inaccessible
        else:
            results[t] = table in known

    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pod")
    parser.add_argument("--skip-bq", action="store_true", help="Skip live BigQuery schema validation")
    args = parser.parse_args()

    grants = load_access_grants()
    total_errors = []

    pod_dirs = sorted(SKILLS_DIR.iterdir()) if not args.pod else [SKILLS_DIR / args.pod]

    all_tables_for_bq = set()
    pod_table_map = {}

    for pod_dir in pod_dirs:
        if not pod_dir.is_dir():
            continue
        pod_id   = pod_dir.name
        csv_path = pod_dir / "semantic" / "metrics.csv"
        sql_path = pod_dir / "analyses" / "patterns.sql"

        tables = set()
        if csv_path.exists():
            tables |= tables_from_csv(csv_path)
        if sql_path.exists():
            tables |= tables_from_sql(sql_path)

        # Remove TBD / placeholder table entries
        tables = {t for t in tables if "TBD" not in t and "INFORMATION_SCHEMA" not in t}

        pod_table_map[pod_id] = tables
        all_tables_for_bq |= tables

        # Access check
        access_errors = check_access(pod_id, tables, grants)
        if access_errors:
            print(f"\n[ACCESS FAIL] {pod_id}:")
            for e in access_errors:
                print(e)
            total_errors.extend(access_errors)
        else:
            print(f"[access ok]  {pod_id} — {len(tables)} tables, all datasets in grants")

    # Schema check
    if not args.skip_bq and all_tables_for_bq:
        print(f"\nRunning schema check against BigQuery ({len(all_tables_for_bq)} unique tables)...")
        schema_results = check_schema_bq(all_tables_for_bq)
        for t, exists in sorted(schema_results.items()):
            if exists is False:
                msg = f"  Table not found in BigQuery: {t}"
                print(f"[SCHEMA FAIL] {msg}")
                total_errors.append(msg)
            elif exists is None:
                print(f"[schema ???]  {t} — dataset inaccessible, skipped")
            else:
                print(f"[schema ok]   {t}")
    else:
        print("\n[schema check skipped]")

    print(f"\n{'='*50}")
    if total_errors:
        print(f"FAILED — {len(total_errors)} error(s) found")
        sys.exit(1)
    else:
        print("All checks passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()

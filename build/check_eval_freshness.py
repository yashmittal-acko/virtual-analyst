#!/usr/bin/env python3
"""
check_eval_freshness.py

Two checks:
1. Eval age — warns when a confirmed eval's period is > 90 days ago.
   Golden answers go stale as pipelines add records, correct historical data,
   or metric definitions shift. Stale evals pass CI but are wrong.

2. Pipeline freshness — checks each table in pipeline_health.yaml against
   its freshness_sla. Flags tables that haven't refreshed as expected.

Usage:
    python3 build/check_eval_freshness.py                # both checks
    python3 build/check_eval_freshness.py --evals-only   # only eval age
    python3 build/check_eval_freshness.py --pipeline-only # only pipeline
    python3 build/check_eval_freshness.py --warn-only    # exit 0 even if stale (for info only)

Exit 0 = all current. Exit 1 = staleness found (optional based on --warn-only).
"""

import argparse
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import yaml

REPO_ROOT    = Path(__file__).resolve().parent.parent
SKILLS_DIR   = REPO_ROOT / "skills"
PIPELINE_CFG = REPO_ROOT / "registry" / "pipeline_health.yaml"
PROJECT      = "storm-wall-185017"

EVAL_STALE_DAYS     = 90   # warn if eval period is older than this
EVAL_CRITICAL_DAYS  = 180  # error if eval period is older than this


def load_confirmed_evals():
    evals = []
    for yaml_path in sorted(SKILLS_DIR.glob("*/evals/metric_evals.yaml")):
        pod = yaml_path.parts[-3]
        data = yaml.safe_load(yaml_path.read_text())
        for ev in data.get("evals", []):
            if ev.get("status") == "confirmed":
                ev["_pod"] = pod
                evals.append(ev)
    return evals


def check_eval_age(warn_only):
    today = date.today()
    evals = load_confirmed_evals()
    warnings = []
    errors = []

    for ev in evals:
        period_raw = ev.get("period")
        if not period_raw:
            continue
        try:
            period = datetime.strptime(str(period_raw), "%Y-%m-%d").date()
        except ValueError:
            continue

        age_days = (today - period).days

        if age_days > EVAL_CRITICAL_DAYS:
            errors.append((ev["id"], ev["_pod"], age_days, period))
        elif age_days > EVAL_STALE_DAYS:
            warnings.append((ev["id"], ev["_pod"], age_days, period))

    if warnings:
        print(f"\n⚠  STALE EVALS (>{EVAL_STALE_DAYS} days old — re-confirm against current data):")
        for ev_id, pod, age, period in warnings:
            print(f"   {ev_id} [{pod}] — period: {period} ({age} days ago)")

    if errors:
        print(f"\n✗  CRITICAL STALE EVALS (>{EVAL_CRITICAL_DAYS} days — likely wrong, must re-run):")
        for ev_id, pod, age, period in errors:
            print(f"   {ev_id} [{pod}] — period: {period} ({age} days ago)")

    if not warnings and not errors:
        print(f"✓  All {len(evals)} confirmed evals are within {EVAL_STALE_DAYS} days.")

    return (errors, warnings) if not warn_only else ([], [])


def check_pipeline(warn_only):
    if not PIPELINE_CFG.exists():
        print("  [skip] pipeline_health.yaml not found")
        return []

    cfg = yaml.safe_load(PIPELINE_CFG.read_text())
    tables = cfg.get("tables", [])

    try:
        from google.cloud import bigquery
        client = bigquery.Client(project=PROJECT)
    except ImportError:
        print("  [skip] google-cloud-bigquery not installed — pipeline check skipped")
        return []

    today = date.today()
    issues = []

    for t in tables:
        table  = t["table"]
        query  = t["check_query"]
        sla    = t.get("freshness_sla", "T-1")
        alert  = t.get("alert_if_stale_days", 2)
        pod    = t.get("pod", "unknown")

        try:
            rows = list(client.query(query).result())
            if not rows or rows[0][0] is None:
                print(f"  [warn] {table} — no data returned from freshness check")
                continue
            latest = rows[0][0]
            if isinstance(latest, str):
                latest = datetime.strptime(latest, "%Y-%m-%d").date()
            lag_days = (today - latest).days

            if lag_days > alert:
                issues.append((table, pod, latest, lag_days, alert))
                print(f"  [STALE] {table} [{pod}] — latest: {latest} ({lag_days} days ago, SLA: {sla})")
            else:
                print(f"  [ok]    {table} [{pod}] — latest: {latest} ({lag_days}d lag)")
        except Exception as e:
            print(f"  [err]   {table} — {e}")

    return [] if warn_only else issues


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evals-only",    action="store_true")
    parser.add_argument("--pipeline-only", action="store_true")
    parser.add_argument("--warn-only",     action="store_true", help="Exit 0 even if stale")
    args = parser.parse_args()

    all_errors = []

    if not args.pipeline_only:
        print("── Eval freshness check ──────────────────────────")
        errors, warnings = check_eval_age(args.warn_only)
        all_errors.extend(errors)

    if not args.evals_only:
        print("\n── Pipeline freshness check ──────────────────────")
        pipeline_issues = check_pipeline(args.warn_only)
        all_errors.extend(pipeline_issues)

    print(f"\n{'='*50}")
    if all_errors:
        print(f"Action required: {len(all_errors)} staleness issue(s) found.")
        print("Re-run the affected evals against current data and update expected_value.")
        sys.exit(1)
    else:
        print("All freshness checks passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
run_evals.py
Reads every confirmed eval from skills/*/evals/metric_evals.yaml,
executes the corresponding query against BigQuery, and checks the
result against the expected_value within tolerance_pct.

Requirements:
    pip install google-cloud-bigquery pyyaml

Usage:
    python3 build/run_evals.py                   # all pods
    python3 build/run_evals.py --pod adsc        # one pod
    python3 build/run_evals.py --pod adsc --id adsc_001  # one eval
    python3 build/run_evals.py --dry-run         # print queries, don't run
    python3 build/run_evals.py --output results.json

Authentication:
    Set GOOGLE_APPLICATION_CREDENTIALS to a service account with
    BigQuery Data Viewer + BigQuery Job User on storm-wall-185017.
    Or use Application Default Credentials (gcloud auth login).
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

import yaml

REPO_ROOT   = Path(__file__).resolve().parent.parent
SKILLS_DIR  = REPO_ROOT / "skills"
PROJECT_ID  = "storm-wall-185017"

# ── BigQuery queries mapped to each eval ────────────────────────────────────
# Each eval's sql field is a description, not executable SQL.
# The canonical queries live here, keyed by eval id.
# When an eval is promoted to confirmed, its query is added here.

EVAL_QUERIES = {

    # ── ADSC (AVA) ──────────────────────────────────────────────────────────
    "adsc_001": {
        "query": """
            SELECT COUNT(DISTINCT id) AS result
            FROM `storm-wall-185017.adsc_gold.fact_adsc_orders`
            WHERE created_date BETWEEN '2026-08-01' AND '2026-08-31'
              AND UPPER(TRIM(status)) <> 'CANCELLED'
        """,
        "result_column": "result",
        "expected": 2366,
    },
    "adsc_002": {
        "query": """
            SELECT ROUND(
              SAFE_DIVIDE(COUNTIF(nps_score >= 9) - COUNTIF(nps_score <= 6), COUNT(*)) * 100,
            1) AS result
            FROM `storm-wall-185017.adsc_gold.fact_adsc_nps`
            WHERE created_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 34.8,
    },
    "adsc_003": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(
              COUNT(DISTINCT CASE WHEN UPPER(TRIM(o.status)) <> 'CANCELLED' THEN a.id END),
              COUNT(DISTINCT a.id)
            ) * 100, 1) AS result
            FROM `storm-wall-185017.adsc_gold.fact_adsc_appointments` a
            LEFT JOIN `storm-wall-185017.adsc_gold.fact_adsc_orders` o ON a.id = o.appointment_id
            WHERE a.status IN ('COMPLETED','PAYMENT_CONFIRMED','PICKUP_ADDRESS','RESCHEDULED','SCHEDULED')
              AND a.created_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 80.5,
    },
    "adsc_004": {
        "query": """
            WITH cohort AS (
              SELECT DISTINCT phone_hashed, first_order_month
              FROM `storm-wall-185017.adsc_gold.adsc_repeat_view_orders_base`
              WHERE first_order_month = '2025-10-01' AND user_type = '1. New user'
            ),
            repeaters AS (
              SELECT DISTINCT r.phone_hashed
              FROM `storm-wall-185017.adsc_gold.adsc_repeat_view_orders_base` r
              JOIN cohort c ON r.phone_hashed = c.phone_hashed
              WHERE r.user_type IN ('2. Repeat same month','3. Repeat user')
                AND r.order_month BETWEEN '2025-10-01' AND '2026-04-01'
                AND r.first_order_month = '2025-10-01'
            )
            SELECT ROUND(
              SAFE_DIVIDE(COUNT(DISTINCT r.phone_hashed), COUNT(DISTINCT c.phone_hashed)) * 100, 1
            ) AS result
            FROM cohort c LEFT JOIN repeaters r ON c.phone_hashed = r.phone_hashed
        """,
        "result_column": "result",
        "expected": 16.0,
    },
    "adsc_005": {
        "query": """
            SELECT
              COUNTIF(user_type = '1. New user')           AS new_user,
              COUNTIF(user_type = '2. Repeat same month')  AS repeat_same_month,
              COUNTIF(user_type = '3. Repeat user')        AS repeat_user
            FROM `storm-wall-185017.adsc_gold.adsc_repeat_view_orders_base`
            WHERE order_month = '2026-08-01'
        """,
        "result_columns": {"new_user": 1305, "repeat_same_month": 198, "repeat_user": 863},
    },

    "fora_005": {
        "query": """
            SELECT
              COALESCE(NULLIF(transfer_to_external_reason, ''), 'Reason Not Available') AS reason,
              COUNT(DISTINCT dispatch_id) AS external_tasks
            FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
            WHERE level = 'Child'
              AND dispatch_partner_type = 'EXTERNAL'
              AND serviceable_flag = 1
              AND appointment_date BETWEEN '2026-08-01' AND '2026-08-31'
            GROUP BY reason
            ORDER BY external_tasks DESC
            LIMIT 1
        """,
        "result_columns": {"reason": "OUTSIDE_SHIFT_HOURS", "external_tasks": 415},
    },
    # ── GIVA (User Growth) ───────────────────────────────────────────────────
    "giva_001": {
        "query": """
            SELECT SUM(CASE WHEN is_reachable = 1 THEN user_count ELSE 0 END) AS result
            FROM `storm-wall-185017.central_gold.user_growth_master_agg`
            WHERE month = '2026-08-01'
        """,
        "result_column": "result",
        "expected": 7733805,
    },
    "giva_002": {
        "query": """
            SELECT SUM(CASE WHEN app_open_flag = 1 THEN user_count ELSE 0 END) AS result
            FROM `storm-wall-185017.central_gold.user_growth_master_agg`
            WHERE month = '2026-08-01'
        """,
        "result_column": "result",
        "expected": 2465813,
    },
    "giva_003": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(
              SUM(CASE WHEN health_ever_customer=1 AND life_ever_customer=1 THEN user_count ELSE 0 END),
              SUM(CASE WHEN health_ever_customer=1 THEN user_count ELSE 0 END)
            ) * 100, 2) AS result
            FROM `storm-wall-185017.central_gold.user_growth_master_agg`
            WHERE month = '2026-08-01'
        """,
        "result_column": "result",
        "expected": 2.59,
    },
    "giva_004": {
        "query": """
            SELECT SUM(user_count) AS result
            FROM `storm-wall-185017.central_gold.user_growth_master_agg`
            WHERE month = '2026-08-01'
              AND car_ever_customer = 1 AND bike_ever_customer = 0 AND is_reachable = 1
        """,
        "result_column": "result",
        "expected": 733196,
    },
    "giva_005": {
        "query": """
            SELECT SUM(user_count) AS result
            FROM `storm-wall-185017.central_gold.user_growth_master_agg`
            WHERE month = '2026-08-01'
              AND event_metrics LIKE '%vas_challan_success%'
        """,
        "result_column": "result",
        "expected": 976031,
    },

    # ── AVI (Retail Travel) ──────────────────────────────────────────────────
    "avi_001": {
        "query": """
            SELECT COUNT(DISTINCT policyid) AS result
            FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_policy_dashboard`
            WHERE purchase_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 4333,
    },
    "avi_002": {
        "query": """
            SELECT ROUND(SUM(policy_gwp_1), 0) AS result
            FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_policy_dashboard`
            WHERE purchase_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 8327524,
    },
    "avi_003": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(SUM(sales_flag), SUM(quote_flag)) * 100, 1) AS result
            FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_l0_funnel_dashboard`
            WHERE date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 28.6,
    },
    "avi_004": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(SUM(attr_sale_flag), SUM(attr_visit_flag)) * 100, 1) AS result
            FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_l0_funnel_dashboard`
            WHERE date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 0.7,
    },
    "avi_005": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(SUM(policy_gwp_1), COUNT(DISTINCT policyid)), 0) AS result
            FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_policy_dashboard`
            WHERE purchase_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 1922,
    },

    # ── ACE (Escalation) ─────────────────────────────────────────────────────
    "ace_001": {
        "query": """
            SELECT COUNT(DISTINCT ticket_id) AS result
            FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
            WHERE DATE(created_at) BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 3309,
    },
    "ace_002": {
        "query": """
            SELECT
              escalation_lob,
              COUNTIF(resolution_tat_bucket = '1. <24H') AS lt_24h,
              COUNT(DISTINCT ticket_id) AS total_auto
            FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
            WHERE DATE(created_at) BETWEEN '2026-08-01' AND '2026-08-31'
              AND escalation_lob = 'Auto'
            GROUP BY escalation_lob
        """,
        "result_columns": {"lt_24h": 298, "total_auto": 717},
    },
    "ace_003": {
        "query": """
            SELECT
              COUNTIF(total_claim_cnt > 0) AS claim_escalations,
              COUNT(DISTINCT ticket_id)    AS total_escalations,
              ROUND(SAFE_DIVIDE(COUNTIF(total_claim_cnt > 0),
                COUNT(DISTINCT ticket_id)) * 100, 1) AS claim_pct
            FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
            WHERE DATE(created_at) BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_columns": {"claim_escalations": 3309, "total_escalations": 3309, "claim_pct": 100.0},
    },
    # ── ACE (Escalation) — continued ─────────────────────────────────────────
    "ace_004": {
        "query": """
            SELECT COUNTIF(reopened_at IS NOT NULL) AS result
            FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
            WHERE DATE(created_at) BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 753,
    },
    "ace_005": {
        "query": """
            SELECT COUNTIF(disputed_flag = TRUE) AS result
            FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
            WHERE DATE(created_at) BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 550,
    },

    # ── FIA (Fleet Intelligence) ─────────────────────────────────────────────
    "fia_001": {
        "query": """
            SELECT COUNT(DISTINCT uni_key) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
            WHERE task_slot_date BETWEEN '2026-08-01' AND '2026-08-31'
              AND final_slot_flag = 1 AND final_status_corrected = 'DONE'
        """,
        "result_column": "result",
        "expected": 24745,
    },
    "fia_002": {
        "query": """
            SELECT ROUND(
              SAFE_DIVIDE(COUNTIF(on_time_reach_flag = 'Off Time'), COUNT(DISTINCT uni_key)) * 100, 1
            ) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
            WHERE task_slot_date BETWEEN '2026-08-01' AND '2026-08-31'
              AND final_slot_flag = 1 AND final_status_corrected = 'DONE'
        """,
        "result_column": "result",
        "expected": 9.6,
    },
    "fia_003": {
        "query": """
            SELECT ROUND(
              SAFE_DIVIDE(
                COUNTIF(started_on_time_flag=0 AND start_trip_ts IS NOT NULL AND on_time_reach_flag='Off Time'),
                COUNTIF(on_time_reach_flag='Off Time')
              ) * 100, 1
            ) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
            WHERE task_slot_date BETWEEN '2026-08-01' AND '2026-08-31'
              AND final_slot_flag = 1 AND final_status_corrected = 'DONE'
        """,
        "result_column": "result",
        "expected": 38.0,
    },
    "fia_004": {
        "query": """
            SELECT ROUND(
              SAFE_DIVIDE(COUNTIF(served_customer_flag = 1), COUNT(DISTINCT availability_customer_day_id)) * 100, 1
            ) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_fops_slot_availability_customer_day`
            WHERE availability_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 93.2,
    },
    "fia_005": {
        "query": """
            SELECT ROUND(AVG(wait_time_at_customer_location_minutes), 1) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
            WHERE task_slot_date BETWEEN '2026-08-01' AND '2026-08-31'
              AND wait_time_at_customer_location_minutes IS NOT NULL
        """,
        "result_column": "result",
        "expected": 9.5,
    },

    # ── FORA (Fleet RSA CRM) ─────────────────────────────────────────────────
    "fora_001": {
        "query": """
            SELECT COUNT(DISTINCT dispatch_id) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
            WHERE level = 'Child'
              AND appointment_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 4078,
    },
    "fora_002": {
        "query": """
            SELECT ROUND(
              SAFE_DIVIDE(COUNT(DISTINCT IF(dispatch_status='COMPLETED', dispatch_id, NULL)),
                COUNT(DISTINCT dispatch_id)) * 100, 1
            ) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
            WHERE level = 'Child'
              AND appointment_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 68.9,
    },
    "fora_003": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(
              COUNT(DISTINCT IF(serviceable_flag=1 AND dispatch_partner_type='EXTERNAL', dispatch_id, NULL)),
              COUNT(DISTINCT IF(serviceable_flag=1, dispatch_id, NULL))
            ) * 100, 1) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
            WHERE level = 'Child'
              AND appointment_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 45.2,
    },
    "fora_004": {
        "query": """
            SELECT ROUND(SAFE_DIVIDE(
              COUNT(DISTINCT IF(tat_adherence_flag='On Time' AND dispatch_status='COMPLETED', dispatch_id, NULL)),
              COUNT(DISTINCT IF(dispatch_status='COMPLETED', dispatch_id, NULL))
            ) * 100, 1) AS result
            FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
            WHERE level = 'Child'
              AND appointment_date BETWEEN '2026-08-01' AND '2026-08-31'
        """,
        "result_column": "result",
        "expected": 71.8,
    },
}


def load_confirmed_evals(pod_filter=None, id_filter=None):
    evals = []
    for yaml_path in sorted(SKILLS_DIR.glob("*/evals/metric_evals.yaml")):
        pod = yaml_path.parts[-3]
        if pod_filter and pod != pod_filter:
            continue
        data = yaml.safe_load(yaml_path.read_text())
        for ev in data.get("evals", []):
            if ev.get("status") != "confirmed":
                continue
            if id_filter and ev["id"] != id_filter:
                continue
            ev["_pod"] = pod
            evals.append(ev)
    return evals


def run_query(client, query):
    import google.cloud.bigquery as bq
    job = client.query(query.strip())
    rows = list(job.result())
    return rows


def check_result(ev, rows):
    if not rows:
        return False, "no rows returned"

    row = rows[0]

    # Multi-column check
    if "result_columns" in EVAL_QUERIES.get(ev["id"], {}):
        expected_map = EVAL_QUERIES[ev["id"]]["result_columns"]
        tol = ev.get("tolerance_pct", 2) / 100
        errors = []
        for col, exp in expected_map.items():
            actual = row[col]
            try:
                # Numeric comparison with tolerance
                actual_f = float(actual)
                exp_f = float(exp)
                if exp_f == 0:
                    if actual_f != 0:
                        errors.append(f"{col}: expected 0 got {actual_f}")
                elif abs(actual_f - exp_f) / abs(exp_f) > tol:
                    errors.append(f"{col}: expected {exp_f} got {actual_f} (Δ{abs(actual_f-exp_f)/exp_f*100:.1f}%)")
            except (ValueError, TypeError):
                # String comparison — exact match required
                if str(actual) != str(exp):
                    errors.append(f"{col}: expected {exp!r} got {actual!r}")
        return len(errors) == 0, "; ".join(errors) if errors else "ok"

    # Single-column check
    q = EVAL_QUERIES.get(ev["id"], {})
    col = q.get("result_column", "result")
    actual = float(row[col])
    expected = float(q.get("expected", ev.get("expected_value", 0)))
    tol = ev.get("tolerance_pct", 2) / 100

    if expected == 0:
        ok = actual == 0
        return ok, f"expected 0 got {actual}"

    delta_pct = abs(actual - expected) / abs(expected)
    ok = delta_pct <= tol
    msg = f"actual={actual} expected={expected} Δ={delta_pct*100:.2f}% tol={tol*100:.1f}%"
    return ok, msg


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pod")
    parser.add_argument("--id")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--output", help="Write JSON results to this file")
    args = parser.parse_args()

    evals = load_confirmed_evals(args.pod, args.id)
    if not evals:
        print("No confirmed evals found matching filters.")
        sys.exit(0)

    if args.dry_run:
        for ev in evals:
            q = EVAL_QUERIES.get(ev["id"])
            print(f"\n── {ev['id']} [{ev['_pod']}] ──")
            if q:
                print(q["query"].strip())
            else:
                print("  ⚠ No query registered in EVAL_QUERIES")
        sys.exit(0)

    try:
        from google.cloud import bigquery
        client = bigquery.Client(project=PROJECT_ID)
    except ImportError:
        print("ERROR: google-cloud-bigquery not installed. Run: pip install google-cloud-bigquery")
        sys.exit(1)

    results = []
    passed = failed = skipped = 0

    for ev in evals:
        ev_id = ev["id"]
        pod   = ev["_pod"]
        q     = EVAL_QUERIES.get(ev_id)

        if not q:
            print(f"  [SKIP] {ev_id} — no query registered in EVAL_QUERIES")
            skipped += 1
            results.append({"id": ev_id, "pod": pod, "status": "skipped", "reason": "no query"})
            continue

        t0 = time.time()
        try:
            rows = run_query(client, q["query"])
            ok, msg = check_result(ev, rows)
            elapsed = round(time.time() - t0, 1)
            status = "PASS" if ok else "FAIL"
            symbol = "✓" if ok else "✗"
            print(f"  [{symbol}] {ev_id} [{pod}] — {status} | {msg} | {elapsed}s")
            results.append({"id": ev_id, "pod": pod, "status": status, "detail": msg, "elapsed_s": elapsed})
            if ok:
                passed += 1
            else:
                failed += 1
        except Exception as e:
            elapsed = round(time.time() - t0, 1)
            print(f"  [ERR] {ev_id} [{pod}] — {e}")
            results.append({"id": ev_id, "pod": pod, "status": "error", "detail": str(e), "elapsed_s": elapsed})
            failed += 1

    print(f"\n{'='*50}")
    print(f"Evals: {passed} passed  {failed} failed  {skipped} skipped  (total {len(evals)})")
    print(f"{'='*50}")

    if args.output:
        Path(args.output).write_text(json.dumps(results, indent=2))
        print(f"Results written to {args.output}")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()

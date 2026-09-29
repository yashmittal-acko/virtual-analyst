-- ============================================================
-- ACE — Approved SQL Patterns
-- Project: storm-wall-185017
-- Canonical table: cs_gold.datamart_escalation_enriched
-- Owner: anurag.gupta1@acko.tech
-- VERIFIED SCHEMA (2026-09-29):
--   ticket_id INT64, created_at TIMESTAMP, escalation_lob STRING
--   total_claim_cnt INT64   (no claim_flag column)
--   resolution_tat_bucket STRING (no tat_sla_flag column)
--   reopened_at TIMESTAMP   (no reopened_flag column)
--   disputed_flag BOOL      (use = TRUE not = 1)
--   status STRING, resolution_tat_hrs INT64
-- ============================================================

-- PATTERN 1: Monthly Escalation Volume by LOB
SELECT
  DATE_TRUNC(DATE(created_at), MONTH) AS month,
  escalation_lob,
  COUNT(DISTINCT ticket_id) AS escalation_count
FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
WHERE DATE(created_at) BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month, escalation_lob
ORDER BY month, escalation_count DESC;

-- PATTERN 2: Claim vs Non-Claim Split
-- No claim_flag column. Claim = total_claim_cnt > 0.
SELECT
  DATE_TRUNC(DATE(created_at), MONTH) AS month,
  escalation_lob,
  COUNTIF(total_claim_cnt > 0)                    AS claim_escalations,
  COUNTIF(total_claim_cnt = 0 OR total_claim_cnt IS NULL) AS non_claim_escalations,
  COUNT(DISTINCT ticket_id)                       AS total_escalations,
  ROUND(SAFE_DIVIDE(
    COUNTIF(total_claim_cnt > 0), COUNT(DISTINCT ticket_id)) * 100, 1) AS claim_pct
FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
WHERE DATE(created_at) BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month, escalation_lob
ORDER BY month, total_escalations DESC;

-- PATTERN 3: TAT Resolution Band Distribution
-- No tat_sla_flag column. Use resolution_tat_bucket as SLA proxy.
-- Confirmed live values: '1. <24H', '2. <48H', '3. <72H', '4. <7D',
--                        '5. <15D', '6. <30D', '7. <60D', '9.Pending'
SELECT
  DATE_TRUNC(DATE(created_at), MONTH) AS month,
  escalation_lob,
  COUNTIF(resolution_tat_bucket = '1. <24H') AS lt_24h,
  COUNTIF(resolution_tat_bucket = '2. <48H') AS h24_48h,
  COUNTIF(resolution_tat_bucket = '3. <72H') AS h48_72h,
  COUNTIF(resolution_tat_bucket = '4. <7D')  AS lt_7d,
  COUNTIF(resolution_tat_bucket = '9.Pending') AS pending,
  COUNT(DISTINCT ticket_id) AS total,
  ROUND(SAFE_DIVIDE(COUNTIF(resolution_tat_bucket = '1. <24H'),
    COUNT(DISTINCT ticket_id)) * 100, 1) AS lt_24h_pct
FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
WHERE DATE(created_at) BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month, escalation_lob
ORDER BY month;

-- PATTERN 4: Reopened + Disputed Tickets (Quality Flags)
-- reopened_at IS NOT NULL (no reopened_flag column)
-- disputed_flag is BOOL — use = TRUE not = 1
SELECT
  DATE_TRUNC(DATE(created_at), MONTH) AS month,
  escalation_lob,
  COUNT(DISTINCT ticket_id)              AS total_tickets,
  COUNTIF(reopened_at IS NOT NULL)       AS reopened,
  COUNTIF(disputed_flag = TRUE)          AS disputed,
  ROUND(SAFE_DIVIDE(COUNTIF(reopened_at IS NOT NULL),
    COUNT(DISTINCT ticket_id)) * 100, 1) AS reopen_rate_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(disputed_flag = TRUE),
    COUNT(DISTINCT ticket_id)) * 100, 1) AS dispute_rate_pct
FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
WHERE DATE(created_at) BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month, escalation_lob
ORDER BY month;

-- PATTERN 5: Pending Tickets (Point-in-Time)
SELECT
  escalation_lob,
  resolution_tat_bucket AS bucket,
  COUNT(DISTINCT ticket_id) AS pending_tickets
FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
WHERE resolution_tat_bucket = '9.Pending'
  AND DATE(created_at) <= CURRENT_DATE() - 1
GROUP BY escalation_lob, resolution_tat_bucket
ORDER BY pending_tickets DESC;

-- PATTERN 6: Escalation per 1K Claims (Normalized Rate)
WITH escalations AS (
  SELECT
    DATE_TRUNC(DATE(created_at), MONTH) AS month,
    escalation_lob,
    COUNT(DISTINCT ticket_id) AS esc_count
  FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
  WHERE DATE(created_at) BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  GROUP BY month, escalation_lob
),
claims AS (
  SELECT
    DATE_TRUNC(claim_month, MONTH) AS month,
    lob,
    SUM(total_claims) AS total_claims
  FROM `storm-wall-185017.cs_gold.fact_claim_month`
  WHERE claim_month BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  GROUP BY month, lob
)
SELECT
  e.month,
  e.escalation_lob,
  e.esc_count,
  c.total_claims,
  ROUND(SAFE_DIVIDE(e.esc_count, c.total_claims / 1000), 2) AS esc_per_1k_claims
FROM escalations e
LEFT JOIN claims c ON e.month = c.month AND e.escalation_lob = c.lob
ORDER BY e.month, esc_per_1k_claims DESC;

-- PATTERN 7: Resolution Time Percentiles (P50 / P90)
SELECT
  escalation_lob,
  ROUND(PERCENTILE_CONT(resolution_tat_hrs, 0.5) OVER (PARTITION BY escalation_lob), 1) AS p50_hrs,
  ROUND(PERCENTILE_CONT(resolution_tat_hrs, 0.9) OVER (PARTITION BY escalation_lob), 1) AS p90_hrs,
  COUNT(DISTINCT ticket_id) AS resolved_tickets
FROM `storm-wall-185017.cs_gold.datamart_escalation_enriched`
WHERE DATE(created_at) BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  AND resolution_tat_hrs IS NOT NULL
GROUP BY escalation_lob, resolution_tat_hrs
QUALIFY ROW_NUMBER() OVER (PARTITION BY escalation_lob ORDER BY resolution_tat_hrs) = 1;

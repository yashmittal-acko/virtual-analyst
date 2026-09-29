-- ============================================================
-- ADSC (AVA) — Approved SQL Patterns
-- Project: storm-wall-185017 | Dataset: adsc_gold
-- Owner: yash.mittal@acko.tech
-- VERIFIED SCHEMA (2026-09-29):
--   fact_adsc_orders: PK=id, date=created_date, status (UPPER TRIM <> 'CANCELLED')
--   fact_adsc_nps:    nps_score INT, created_date DATE
--   fact_adsc_appointments: PK=id, status filter required (5 valid values)
--   adsc_repeat_view_orders_base: phone_hashed, first_order_month, order_month, user_type
--   NO columns: payment_status, job_status, order_date, nps_category, customer_id
-- ============================================================

-- PATTERN 1: Monthly Valid Orders
-- valid = UPPER(TRIM(status)) <> 'CANCELLED'. PK is id not order_id.
SELECT
  DATE_TRUNC(created_date, MONTH) AS month,
  COUNT(DISTINCT id) AS valid_orders
FROM `storm-wall-185017.adsc_gold.fact_adsc_orders`
WHERE created_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  AND UPPER(TRIM(status)) <> 'CANCELLED'
  AND garage_id <> 'acko'   -- exclude test data
GROUP BY month
ORDER BY month;

-- PATTERN 2: Appointment-to-Order Conversion
-- Appointment valid statuses (5 only — no others count)
SELECT
  DATE_TRUNC(a.created_date, MONTH) AS month,
  COUNT(DISTINCT a.id) AS valid_appointments,
  COUNT(DISTINCT CASE WHEN UPPER(TRIM(o.status)) <> 'CANCELLED' THEN a.id END) AS converted,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN UPPER(TRIM(o.status)) <> 'CANCELLED' THEN a.id END),
    COUNT(DISTINCT a.id)
  ) * 100, 1) AS appt_to_order_pct
FROM `storm-wall-185017.adsc_gold.fact_adsc_appointments` a
LEFT JOIN `storm-wall-185017.adsc_gold.fact_adsc_orders` o
  ON a.id = o.appointment_id
WHERE a.status IN ('COMPLETED','PAYMENT_CONFIRMED','PICKUP_ADDRESS','RESCHEDULED','SCHEDULED')
  AND a.created_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

-- PATTERN 3: NPS Score by Month
-- nps_score INT: >=9 = Promoter, <=6 = Detractor, 7-8 = Passive
-- Date basis: fact_adsc_nps.created_date (no join to orders needed)
SELECT
  DATE_TRUNC(created_date, MONTH) AS month,
  COUNT(*) AS responses,
  COUNTIF(nps_score >= 9) AS promoters,
  COUNTIF(nps_score <= 6) AS detractors,
  ROUND(
    SAFE_DIVIDE(COUNTIF(nps_score >= 9) - COUNTIF(nps_score <= 6), COUNT(*)) * 100,
  1) AS nps_score
FROM `storm-wall-185017.adsc_gold.fact_adsc_nps`
WHERE created_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

-- PATTERN 4: NPS Theme L0/L1 Distribution (via ABSA tagged table)
SELECT
  l0_theme,
  l1_theme,
  COUNT(*) AS response_count,
  ROUND(SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER()) * 100, 1) AS pct_of_total
FROM `storm-wall-185017.adsc_gold.fact_adsc_nps_tagged`
WHERE created_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY l0_theme, l1_theme
ORDER BY response_count DESC;

-- PATTERN 5: New vs Repeat User Mix
-- Source: adsc_repeat_view_orders_base (has user_type, fact_adsc_orders does not)
-- user_type values: '1. New user', '2. Repeat same month', '3. Repeat user'
SELECT
  user_type,
  COUNT(DISTINCT orders_id) AS valid_orders,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT orders_id),
    SUM(COUNT(DISTINCT orders_id)) OVER()) * 100, 1) AS pct
FROM `storm-wall-185017.adsc_gold.adsc_repeat_view_orders_base`
WHERE order_month = DATE_TRUNC(DATE '<target_month>', MONTH)
GROUP BY user_type
ORDER BY user_type;

-- PATTERN 6: M6/M9/M12 Cohort Repeat Rate
-- Source: adsc_repeat_view_orders_base (not fact_adsc_orders — no customer_id there)
-- Replace <cohort_month_start> with e.g. '2025-10-01'
WITH cohort AS (
  SELECT DISTINCT phone_hashed, first_order_month
  FROM `storm-wall-185017.adsc_gold.adsc_repeat_view_orders_base`
  WHERE first_order_month = DATE '<cohort_month_start>'
    AND user_type = '1. New user'
),
repeaters AS (
  SELECT DISTINCT r.phone_hashed,
    MAX(CASE WHEN r.order_month <= DATE_ADD(DATE '<cohort_month_start>', INTERVAL 6 MONTH) THEN 1 ELSE 0 END) AS returned_m6,
    MAX(CASE WHEN r.order_month <= DATE_ADD(DATE '<cohort_month_start>', INTERVAL 9 MONTH) THEN 1 ELSE 0 END) AS returned_m9,
    MAX(CASE WHEN r.order_month <= DATE_ADD(DATE '<cohort_month_start>', INTERVAL 12 MONTH) THEN 1 ELSE 0 END) AS returned_m12
  FROM `storm-wall-185017.adsc_gold.adsc_repeat_view_orders_base` r
  JOIN cohort c ON r.phone_hashed = c.phone_hashed
  WHERE r.user_type IN ('2. Repeat same month', '3. Repeat user')
    AND r.first_order_month = DATE '<cohort_month_start>'
    AND r.order_month > DATE '<cohort_month_start>'
  GROUP BY r.phone_hashed
)
SELECT
  COUNT(DISTINCT c.phone_hashed)                                  AS cohort_size,
  ROUND(SAFE_DIVIDE(COUNTIF(r.returned_m6  = 1), COUNT(DISTINCT c.phone_hashed)) * 100, 1) AS m6_repeat_rate_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(r.returned_m9  = 1), COUNT(DISTINCT c.phone_hashed)) * 100, 1) AS m9_repeat_rate_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(r.returned_m12 = 1), COUNT(DISTINCT c.phone_hashed)) * 100, 1) AS m12_repeat_rate_pct
FROM cohort c
LEFT JOIN repeaters r ON c.phone_hashed = r.phone_hashed;

-- PATTERN 7: Demand Funnel
SELECT
  DATE_TRUNC(event_date, MONTH) AS month,
  SUM(CASE WHEN funnel_stage = 'Aware'       THEN user_count ELSE 0 END) AS aware,
  SUM(CASE WHEN funnel_stage = 'Appointment' THEN user_count ELSE 0 END) AS appointment,
  SUM(CASE WHEN funnel_stage = 'Order'       THEN user_count ELSE 0 END) AS orders_users,
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN funnel_stage = 'Appointment' THEN user_count ELSE 0 END),
    SUM(CASE WHEN funnel_stage = 'Aware'       THEN user_count ELSE 0 END)) * 100, 1) AS aware_to_appt_pct,
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN funnel_stage = 'Order'       THEN user_count ELSE 0 END),
    SUM(CASE WHEN funnel_stage = 'Appointment' THEN user_count ELSE 0 END)) * 100, 1) AS appt_to_order_pct
FROM `storm-wall-185017.adsc_gold.fact_adsc_demand_funnel`
WHERE event_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

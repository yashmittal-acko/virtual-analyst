-- ============================================================
-- GIVA — Approved SQL Patterns
-- Project: storm-wall-185017 | Table: central_gold.user_growth_master_agg
-- Owner: yash.agnihotri@acko.tech
-- NOTE: Always query user_growth_master_agg — never the base table directly.
--       All aggregations use SUM(user_count); never COUNT(DISTINCT user_id).
--       Auto LOB = Car + Bike combined (use OR, not sum separately).
-- ============================================================

-- PATTERN 1: Reachable + MAU MoM Trend
-- Use for: top-line growth health
SELECT
  month,
  SUM(CASE WHEN is_reachable = 1 THEN user_count ELSE 0 END) AS reachable_users,
  SUM(CASE WHEN app_open_flag = 1 THEN user_count ELSE 0 END) AS mau
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month >= '<from_month>'   -- e.g. '2026-01-01'
GROUP BY month
ORDER BY month;

-- PATTERN 2: Lifecycle Bucket Breakdown
-- Use for: MAU composition, dormancy analysis
-- Sanity check: New + Returning + Resurrected = MAU (app_open_flag=1 total)
SELECT
  month,
  app_open_lifecycle_bucket,
  SUM(user_count) AS user_count
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month >= '<from_month>'
GROUP BY month, app_open_lifecycle_bucket
ORDER BY month, app_open_lifecycle_bucket;

-- PATTERN 3: Cross-sell — out of X base, what's the Y penetration
-- Example: out of health base, what's the life cross-sell
SELECT
  month,
  SUM(CASE WHEN health_ever_customer = 1 THEN user_count ELSE 0 END) AS health_base,
  SUM(CASE WHEN health_ever_customer = 1 AND life_ever_customer = 1 THEN user_count ELSE 0 END) AS health_and_life,
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN health_ever_customer = 1 AND life_ever_customer = 1 THEN user_count ELSE 0 END),
    SUM(CASE WHEN health_ever_customer = 1 THEN user_count ELSE 0 END)
  ) * 100, 1) AS life_xsell_pct
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month = '<month>'    -- e.g. '2026-08-01'
GROUP BY month;

-- PATTERN 4: Auto LOB Penetration (Car + Bike combined)
-- CRITICAL: never SUM car + bike counts separately; a user may hold both
SELECT
  month,
  SUM(CASE WHEN car_ever_customer = 1 OR bike_ever_customer = 1 THEN user_count ELSE 0 END) AS auto_ever_customer,
  SUM(CASE WHEN car_active = 1 OR bike_active = 1 THEN user_count ELSE 0 END) AS auto_active
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month = '<month>'
GROUP BY month;

-- PATTERN 5: Specific Event Filter (e.g. vas_challan_success)
-- event_metrics is a comma-joined string; always use LIKE, never =
SELECT
  month,
  car_active,
  SUM(user_count) AS user_count
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month = '<month>'
  AND event_metrics LIKE '%vas_challan_success%'
GROUP BY month, car_active
ORDER BY month;

-- PATTERN 6: Reachability Funnel (one statement, step-over-step %)
-- Format each stage as: count (pct of previous stage %)
SELECT
  month,
  SUM(CASE WHEN bike_ever_customer = 1 THEN user_count ELSE 0 END)
    AS bike_ever_customer,
  SUM(CASE WHEN bike_ever_customer = 1 AND is_reachable = 1 THEN user_count ELSE 0 END)
    AS plus_reachable,
  SUM(CASE WHEN bike_ever_customer = 1 AND is_reachable = 1 AND app_open_flag = 1 THEN user_count ELSE 0 END)
    AS plus_opened,
  SUM(CASE WHEN bike_ever_customer = 1 AND is_reachable = 1 AND app_open_flag = 1
    AND event_metrics LIKE '%vas_challan%' THEN user_count ELSE 0 END)
    AS plus_vas_challan
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month = '<month>'
GROUP BY month;

-- PATTERN 7: Cross-sell Target Pool — reachable single-LOB customers
-- Use for: sizing a campaign segment
SELECT
  month,
  SUM(user_count) AS car_only_reachable_pool
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month = '<month>'
  AND car_ever_customer = 1
  AND bike_ever_customer = 0
  AND is_reachable = 1
GROUP BY month;
-- Swap car_ever_customer=1/bike_ever_customer=0 for any other cross-sell direction

-- PATTERN 8: City-Tier Breakdown
-- Use for: geographic prioritization of growth
SELECT
  month,
  City_Group,
  SUM(user_count) AS total_users,
  SUM(CASE WHEN is_reachable = 1 THEN user_count ELSE 0 END) AS reachable_users,
  SUM(CASE WHEN app_open_flag = 1 THEN user_count ELSE 0 END) AS mau
FROM `storm-wall-185017.central_gold.user_growth_master_agg`
WHERE month = '<month>'
GROUP BY month, City_Group
ORDER BY month, City_Group;

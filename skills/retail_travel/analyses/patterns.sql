-- ============================================================
-- AVI — Approved SQL Patterns
-- Project: storm-wall-185017
-- Funnel table:  retail_travel_gold.datamart_retail_travel_l0_funnel_dashboard
-- Policy table:  retail_travel_gold.datamart_retail_travel_policy_dashboard
-- Claims tables: DataMigrator.jarvis_claim, DataMigrator.jarvis_payment,
--                AnalyticsCommon.International_Travel_Insured_Level_v1
-- Owner: parth.trivedi@acko.tech
-- CRITICAL: Always filter `date` partition on funnel table.
--           Always clarify attributed vs non-attributed before running funnel queries.
-- ============================================================

-- PATTERN 1: Funnel Summary (Non-Attributed / Raw View)
-- Use for: raw funnel health. Replace *_flag with attr_*_flag for attributed view.
SELECT
  DATE_TRUNC(date, MONTH) AS month,
  SUM(category_visit_flag)  AS category_visits,
  SUM(visit_flag)           AS visits,
  SUM(entry_flag)           AS entries,
  SUM(quote_flag)           AS quotes,
  SUM(sale_flag)            AS sales,
  ROUND(SAFE_DIVIDE(SUM(entry_flag), SUM(visit_flag)) * 100, 1) AS v2e_pct,
  ROUND(SAFE_DIVIDE(SUM(quote_flag), SUM(entry_flag)) * 100, 1) AS e2q_pct,
  ROUND(SAFE_DIVIDE(SUM(sale_flag), SUM(quote_flag)) * 100, 1) AS q2s_pct,
  ROUND(SAFE_DIVIDE(SUM(sale_flag), SUM(visit_flag)) * 100, 1) AS v2s_pct
FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_l0_funnel_dashboard`
WHERE date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

-- PATTERN 1b: Funnel Summary (Attributed / 5-day attribution window)
SELECT
  DATE_TRUNC(date, MONTH) AS month,
  SUM(attr_category_visit_flag) AS category_visits_attr,
  SUM(attr_visit_flag)          AS visits_attr,
  SUM(attr_entry_flag)          AS entries_attr,
  SUM(attr_quote_flag)          AS quotes_attr,
  SUM(attr_sale_flag)           AS sales_attr,
  ROUND(SAFE_DIVIDE(SUM(attr_sale_flag), SUM(attr_visit_flag)) * 100, 1) AS v2s_pct_attr
FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_l0_funnel_dashboard`
WHERE date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

-- PATTERN 2: Policy KPIs (GWP / NOP / ATS / Members)
-- Use for: revenue and policy volume trend
SELECT
  DATE_TRUNC(purchase_date, MONTH) AS month,
  COUNT(DISTINCT policyid)        AS policy_count,
  COUNT(DISTINCT insuredid)       AS member_count,
  SUM(policy_gwp_1)               AS gwp,
  ROUND(SAFE_DIVIDE(SUM(policy_gwp_1), COUNT(DISTINCT policyid)), 0) AS ats,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT IF(addon_flag = 1, policyid, NULL)),
    COUNT(DISTINCT policyid)
  ) * 100, 1) AS addon_attach_pct
FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_policy_dashboard`
WHERE purchase_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

-- PATTERN 3: RCA by Channel/Platform — Funnel Driver Analysis
-- Use for: understanding what drove a funnel change
SELECT
  DATE_TRUNC(date, MONTH) AS month,
  final_channel,
  platform,
  SUM(visit_flag)   AS visits,
  SUM(sale_flag)    AS sales,
  ROUND(SAFE_DIVIDE(SUM(sale_flag), SUM(visit_flag)) * 100, 1) AS v2s_pct
FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_l0_funnel_dashboard`
WHERE date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month, final_channel, platform
ORDER BY month, visits DESC;

-- PATTERN 4: Policy Mix by Destination / Plan Category
SELECT
  destination_region,
  plan_category,
  COUNT(DISTINCT policyid)  AS policy_count,
  SUM(policy_gwp_1)         AS gwp
FROM `storm-wall-185017.retail_travel_gold.datamart_retail_travel_policy_dashboard`
WHERE purchase_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY destination_region, plan_category
ORDER BY gwp DESC;

-- PATTERN 5: Claims by Cover and Destination (Count Only)
-- Use for: claim frequency analysis. Do NOT add payment data here.
SELECT
  cover_type,
  destination_country,
  COUNT(claim_id) AS claim_count
FROM `storm-wall-185017.DataMigrator.jarvis_claim` jc
JOIN `storm-wall-185017.retail_travel_gold.fact_retail_travel_policy` rtp
  ON jc.policy_id = rtp.policy_id
WHERE jc.created_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY cover_type, destination_country
ORDER BY claim_count DESC;

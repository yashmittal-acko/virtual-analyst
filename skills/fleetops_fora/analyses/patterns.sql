-- ============================================================
-- FORA — Approved SQL Patterns
-- Project: storm-wall-185017
-- Canonical table: fleetops_gold.datamart_rsa_crm_report
-- Owner: anupam.singh@acko.tech
-- CRITICAL RULES:
--   - Always use level='Child' for dashboard task KPIs.
--   - Always use COUNT(DISTINCT dispatch_id) — NEVER COUNT(*).
--     dispatch_id is not unique when unavailable reasons are joined.
--   - External transfer questions: default filter serviceable_flag=1.
--     Only omit if user explicitly opts out — and state that explicitly.
--   - Date for scheduled/dashboard metrics: appointment_date.
--     Date for completed-in-period metrics: resolved_datetime.
--   - Never show/select raw phone column. Use phone_hashed only.
-- ============================================================

-- PATTERN 1: Monthly KPI Summary (Single Query for All Core Metrics)
WITH base AS (
  SELECT
    date_trunc(appointment_date, MONTH) AS appointment_month,
    dispatch_id,
    dispatch_status,
    tat_adherence_flag,
    dispatch_partner_type,
    CASE WHEN serviceable_flag = 1 THEN 'Inhouse Eligible'
         ELSE 'Not Inhouse Eligible' END AS serviceable_tag
  FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
  WHERE level = 'Child'
    AND appointment_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
)
SELECT
  appointment_month,
  count(distinct dispatch_id)                                                         AS scheduled_tasks,
  count(distinct if(dispatch_status = 'COMPLETED', dispatch_id, null))               AS completed_tasks,
  safe_divide(count(distinct if(dispatch_status = 'COMPLETED', dispatch_id, null)),
    count(distinct dispatch_id))                                                      AS completion_pct,
  count(distinct if(dispatch_status = 'CANCELLED', dispatch_id, null))               AS cancelled_tasks,
  safe_divide(count(distinct if(dispatch_status = 'CANCELLED', dispatch_id, null)),
    count(distinct dispatch_id))                                                      AS cancellation_pct,
  count(distinct if(tat_adherence_flag = 'On Time'
    AND dispatch_status = 'COMPLETED', dispatch_id, null))                           AS tat_adherence_tasks,
  safe_divide(count(distinct if(tat_adherence_flag = 'On Time'
    AND dispatch_status = 'COMPLETED', dispatch_id, null)),
    count(distinct if(dispatch_status = 'COMPLETED', dispatch_id, null)))             AS adherence_pct,
  safe_divide(
    count(distinct if(serviceable_tag = 'Inhouse Eligible'
      AND dispatch_partner_type = 'EXTERNAL', dispatch_id, null)),
    count(distinct if(serviceable_tag = 'Inhouse Eligible', dispatch_id, null))
  ) AS external_transfer_pct
FROM base
GROUP BY appointment_month
ORDER BY appointment_month;

-- PATTERN 2: External Transfer Reasons (Inhouse Eligible ONLY — mandatory default)
-- Always filter serviceable_flag=1 unless user explicitly opts out
WITH reason_base AS (
  SELECT
    coalesce(nullif(transfer_to_external_reason, ''), 'Reason Not Available') AS transfer_to_external_reason,
    dispatch_id
  FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
  WHERE level = 'Child'
    AND dispatch_partner_type = 'EXTERNAL'
    AND serviceable_flag = 1            -- default eligibility filter
    AND appointment_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
),
agg AS (
  SELECT
    transfer_to_external_reason,
    count(distinct dispatch_id) AS external_tasks
  FROM reason_base
  GROUP BY transfer_to_external_reason
)
SELECT
  transfer_to_external_reason,
  external_tasks,
  round(100 * safe_divide(external_tasks, sum(external_tasks) OVER()), 2) AS contribution_pct
FROM agg
ORDER BY external_tasks DESC;

-- PATTERN 3: TAT Adherence by City + RSA Type
SELECT
  AckoCity,
  grouped_dispatch_rsa_type,
  count(distinct dispatch_id) AS completed_tasks,
  count(distinct if(tat_adherence_flag = 'On Time', dispatch_id, null)) AS tat_on_time,
  round(safe_divide(count(distinct if(tat_adherence_flag = 'On Time', dispatch_id, null)),
    count(distinct dispatch_id)) * 100, 1) AS adherence_pct
FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
WHERE level = 'Child'
  AND dispatch_status = 'COMPLETED'
  AND appointment_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY AckoCity, grouped_dispatch_rsa_type
ORDER BY completed_tasks DESC;

-- PATTERN 4: Lifecycle Timing Analysis
SELECT
  DATE_TRUNC(appointment_date, MONTH) AS month,
  grouped_dispatch_rsa_type,
  ROUND(AVG(activation_time), 1)          AS avg_activation_mins,
  ROUND(AVG(travel_time), 1)              AS avg_travel_mins,
  ROUND(AVG(dispatch_completion_time), 1) AS avg_completion_mins,
  COUNT(DISTINCT dispatch_id) AS completed_tasks
FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
WHERE level = 'Child'
  AND dispatch_status = 'COMPLETED'
  AND appointment_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month, grouped_dispatch_rsa_type
ORDER BY month;

-- PATTERN 5: Task-Type Conversion Analysis (parent_id based)
-- Use for: did a case type change (e.g. custodian → towing)?
WITH child AS (
  SELECT
    parent_id,
    dispatch_id,
    dispatch_cust_reg_no AS reg_no,
    grouped_dispatch_rsa_type AS task_type,
    dispatch_datetime
  FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
  WHERE level = 'Child'
    AND appointment_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
    AND parent_id IS NOT NULL
    AND dispatch_cust_reg_no IS NOT NULL
    AND dispatch_datetime IS NOT NULL
),
ranked AS (
  SELECT *,
    row_number() OVER (PARTITION BY parent_id ORDER BY dispatch_datetime, dispatch_id) AS rn
  FROM child
),
first_task AS (
  SELECT parent_id, reg_no AS first_reg_no, task_type AS first_type, dispatch_datetime AS first_time
  FROM ranked WHERE rn = 1
),
converted AS (
  SELECT
    r.parent_id, f.first_type, r.task_type AS converted_to_type
  FROM ranked r
  JOIN first_task f USING (parent_id)
  WHERE r.rn > 1
    AND r.reg_no = f.first_reg_no
    AND r.task_type != f.first_type
    AND TIMESTAMP_DIFF(r.dispatch_datetime, f.first_time, MINUTE) BETWEEN 0 AND 300
)
SELECT
  first_type,
  converted_to_type,
  count(distinct parent_id) AS parent_cases
FROM converted
GROUP BY first_type, converted_to_type
ORDER BY first_type, converted_to_type;

-- PATTERN 6: Dashboard Extract (Privacy-safe — phone_hashed only)
SELECT
  level,
  dispatch_date,
  dispatch_id               AS rsa_crm_number,
  dispatch_assignee         AS rsa_advisor,
  dispatch_cust_reg_no      AS registration_number,
  customer_name,
  phone_hashed,             -- NEVER use raw phone column
  policy_number,
  vehicle_make,
  vehicle_model,
  grouped_dispatch_rsa_type AS rsa_service_type,
  dispatch_partner_type     AS partner_type,
  AckoCity                  AS acko_city,
  appointment_date,
  appointment_datetime,
  start_trip_ts,
  reach_customer_ts,
  dispatch_status           AS final_status,
  dispatch_cancellation_reason AS cancellation_reason,
  serviceable_flag,
  transfer_to_external_reason,
  tat_adherence_flag
FROM `storm-wall-185017.fleetops_gold.datamart_rsa_crm_report`
WHERE level = 'Child'
  AND appointment_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY ALL;

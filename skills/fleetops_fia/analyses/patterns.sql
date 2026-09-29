-- ============================================================
-- FIA — Approved SQL Patterns
-- Project: storm-wall-185017
-- Primary table: fleetops_gold.datamart_fops_360
-- Slot table:    fleetops_gold.datamart_fops_slot_availability_customer_day
-- Promise table: fleetops_gold.datamart_serviceos_promise_fe_metrics_tableau
-- Owner: anupam.singh@acko.tech
-- CRITICAL RULES:
--   - There is NO grouped_task_type column — use task_type for task-type cuts.
--   - Duration metrics are NOT restricted to final/DONE by default — use natural
--     eligibility (non-null value). Offer completed-final-slot narrowing as follow-up.
--   - TAT Breach RCA must follow the fixed order: Step 1 = late-start driver
--     breakdown FIRST, Step 2 = geography/dimension cuts second.
--   - Milestone timestamps = FIRST mark of that state in the slot episode.
--   - Never expose raw phone_number. Use customer_phone_hash.
-- ============================================================

-- PATTERN 1: Monthly Completed Tasks + TAT Breach KPIs
SELECT
  DATE_TRUNC(task_slot_date, MONTH) AS month,
  COUNT(DISTINCT uni_key) AS completed_tasks,
  COUNTIF(on_time_reach_flag = 'Off Time') AS tat_breach_tasks,
  ROUND(SAFE_DIVIDE(COUNTIF(on_time_reach_flag = 'Off Time'),
    COUNT(DISTINCT uni_key)) * 100, 1) AS tat_breach_pct,
  COUNTIF(started_on_time_flag = 0 AND start_trip_ts IS NOT NULL) AS late_start_tasks,
  ROUND(SAFE_DIVIDE(COUNTIF(started_on_time_flag = 0 AND start_trip_ts IS NOT NULL),
    COUNT(DISTINCT uni_key)) * 100, 1) AS late_start_pct
FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
WHERE task_slot_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  AND final_slot_flag = 1
  AND final_status_corrected = 'DONE'
GROUP BY month
ORDER BY month;

-- PATTERN 2: TAT Breach RCA — Step 1 (Late-Start Driver Breakdown)
-- MANDATORY FIRST STEP for any TAT breach RCA — run this before geography cuts
WITH breach_base AS (
  SELECT
    uni_key,
    task_slot_date,
    assignee,
    started_on_time_flag,
    start_trip_ts,
    schedule_start_time,
    schedule_end_time,
    LAG(engaged_end_ts) OVER (PARTITION BY assignee, task_slot_date
      ORDER BY schedule_start_time) AS prev_engaged_end_ts,
    LAG(schedule_end_time) OVER (PARTITION BY assignee, task_slot_date
      ORDER BY schedule_start_time) AS prev_schedule_end_time,
    ROW_NUMBER() OVER (PARTITION BY assignee, task_slot_date
      ORDER BY schedule_start_time) AS task_rn
  FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
  WHERE task_slot_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
    AND final_slot_flag = 1
    AND final_status_corrected = 'DONE'
    AND on_time_reach_flag = 'Off Time'
)
SELECT
  COUNTIF(started_on_time_flag = 0 AND start_trip_ts IS NOT NULL) AS late_start_breach,
  COUNTIF(started_on_time_flag = 0 AND task_rn = 1) AS first_task_delay,
  COUNTIF(started_on_time_flag = 0 AND task_rn > 1
    AND prev_engaged_end_ts > schedule_start_time) AS overlap_breach,
  COUNTIF(started_on_time_flag = 0 AND task_rn > 1
    AND prev_engaged_end_ts <= schedule_start_time
    AND TIMESTAMP_DIFF(schedule_start_time, prev_schedule_end_time, MINUTE) > 0) AS idle_gap_breach,
  COUNTIF(started_on_time_flag = 1) AS reached_late_not_late_start,
  COUNT(*) AS total_breach_tasks
FROM breach_base;

-- PATTERN 3: TAT Breach RCA — Step 2 (Geography + Driver Cuts)
-- Run AFTER Step 1 to localize dominant driver
SELECT
  city,
  task_type,
  top8_tag,
  COUNTIF(on_time_reach_flag = 'Off Time') AS breach_tasks,
  COUNT(DISTINCT uni_key) AS total_completed,
  ROUND(SAFE_DIVIDE(COUNTIF(on_time_reach_flag = 'Off Time'),
    COUNT(DISTINCT uni_key)) * 100, 1) AS breach_pct
FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
WHERE task_slot_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  AND final_slot_flag = 1
  AND final_status_corrected = 'DONE'
GROUP BY city, task_type, top8_tag
ORDER BY breach_tasks DESC;

-- PATTERN 4: Duration Metrics (NOT restricted to final/DONE by default)
-- customer_wait_time, travel_time, photoshoot_execution_time, total_task_time
-- After delivering results, ask: "Want this narrowed to completed (final slot, DONE) tasks only?"
SELECT
  DATE_TRUNC(task_slot_date, MONTH) AS month,
  ROUND(AVG(wait_time_at_customer_location_minutes), 1) AS avg_customer_wait_mins,
  ROUND(AVG(travel_time_minutes), 1)        AS avg_travel_mins,
  ROUND(AVG(photoshoot_execution_time_minutes), 1) AS avg_photoshoot_mins,
  ROUND(AVG(engaged_time_minutes), 1)       AS avg_engaged_mins,
  COUNT(*) AS eligible_slots
FROM `storm-wall-185017.fleetops_gold.datamart_fops_360`
WHERE task_slot_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
  AND wait_time_at_customer_location_minutes IS NOT NULL  -- natural eligibility filter only
GROUP BY month
ORDER BY month;

-- PATTERN 5: Slot Availability — Served %, No-Slots Rate
SELECT
  DATE_TRUNC(availability_date, MONTH) AS month,
  COUNT(DISTINCT customer_request_id) AS total_requests,
  COUNTIF(served_flag = 1) AS served_requests,
  ROUND(SAFE_DIVIDE(COUNTIF(served_flag = 1),
    COUNT(DISTINCT customer_request_id)) * 100, 1) AS served_pct,
  COUNTIF(slots_offered_24h_flag = 1) AS offered_within_24h,
  COUNTIF(no_slots_flag = 1) AS no_slots_requests,
  ROUND(SAFE_DIVIDE(COUNTIF(no_slots_flag = 1),
    COUNT(DISTINCT customer_request_id)) * 100, 1) AS no_slots_pct
FROM `storm-wall-185017.fleetops_gold.datamart_fops_slot_availability_customer_day`
WHERE availability_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

-- PATTERN 6: Promise/FE Dashboard Metrics
-- NOTE: These use the promise table's own denominator flags — not fops_360 logic.
--       reach_on_time and started_on_time here differ from fops_360 equivalents.
SELECT
  DATE_TRUNC(promise_date, MONTH) AS month,
  COUNT(DISTINCT promise_id) AS total_promises,
  COUNTIF(valid_promise_flag = 1) AS valid_promises,
  ROUND(SAFE_DIVIDE(COUNTIF(promise_success_flag = 1 AND valid_promise_flag = 1),
    COUNTIF(valid_promise_flag = 1)) * 100, 1) AS promise_success_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(reach_on_time_flag = 1 AND reach_denominator_flag = 1),
    COUNTIF(reach_denominator_flag = 1)) * 100, 1) AS reach_on_time_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(start_adherence_flag = 1 AND start_denominator_flag = 1),
    COUNTIF(start_denominator_flag = 1)) * 100, 1) AS start_adherence_pct
FROM `storm-wall-185017.fleetops_gold.datamart_serviceos_promise_fe_metrics_tableau`
WHERE promise_date BETWEEN DATE '<from_date>' AND DATE '<to_date>'
GROUP BY month
ORDER BY month;

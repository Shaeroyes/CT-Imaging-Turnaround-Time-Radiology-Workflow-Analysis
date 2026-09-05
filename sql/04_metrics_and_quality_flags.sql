/* =============================================================
   04 — WORKFLOW METRICS, QUALITY FLAGS AND KPI VIEW
   CT Imaging Turnaround Time & Radiology Workflow Analysis

   Purpose: convert timestamps into measurable stage durations,
   flag records that fail validation, and expose a single curated
   view for the BI layer.

   The CT workflow decomposes into six sequential stages:

     Order ──► Schedule ──► Arrival ──► Scan Start ──► Scan End
           1            2            3              4
       ──► Report Start ──► Report Finalized
           5                 6

     1 order_to_schedule_min     administrative queue
     2 schedule_to_arrival_min   patient-side lead time
     3 arrival_to_scan_min       departmental wait
     4 scan_duration_min         image acquisition
     5 scan_to_report_start_min  handoff to radiologist
     6 reporting_duration_min    interpretation and sign-off

   Measuring every stage independently is what allows the data —
   rather than an assumption — to identify the bottleneck.
   ============================================================= */

USE ct_imaging_analytics;


-- -------------------------------------------------------------
-- Stage durations
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ct_imaging_analysis;

CREATE TABLE ct_imaging_analysis AS
SELECT
    *,

    TIMESTAMPDIFF(MINUTE, Order_Time,        Scheduled_Time)        AS order_to_schedule_min,
    TIMESTAMPDIFF(MINUTE, Scheduled_Time,    Arrival_Time)          AS schedule_to_arrival_min,
    TIMESTAMPDIFF(MINUTE, Arrival_Time,      Scan_Start_Time)       AS arrival_to_scan_min,
    TIMESTAMPDIFF(MINUTE, Scan_Start_Time,   Scan_End_Time)         AS scan_duration_min,
    TIMESTAMPDIFF(MINUTE, Scan_End_Time,     Report_Start_Time)     AS scan_to_report_start_min,
    TIMESTAMPDIFF(MINUTE, Report_Start_Time, Report_Finalized_Time) AS reporting_duration_min,

    -- Total turnaround: the metric the department is judged on
    TIMESTAMPDIFF(MINUTE, Order_Time,        Report_Finalized_Time) AS total_turnaround_min

FROM ct_imaging_clean;

/* MEASUREMENT NOTE
   TIMESTAMPDIFF(MINUTE, ...) truncates toward zero rather than
   rounding, discarding up to 59 seconds per interval. Total
   turnaround is measured across a single interval, so the bias is
   approximately -0.5 minutes on a ~177 minute metric. Immaterial
   at this scale, but documented rather than left as an unexplained
   discrepancy against any independent recomputation.

   To measure in seconds instead:
       TIMESTAMPDIFF(SECOND, Order_Time, Report_Finalized_Time)/60 */


-- -------------------------------------------------------------
-- Data quality flag
-- Marks records that violate the physical ordering of the
-- workflow. These are excluded from KPIs but retained in the
-- table so the exclusion is auditable and countable.
-- -------------------------------------------------------------
ALTER TABLE ct_imaging_analysis
ADD COLUMN data_quality_flag VARCHAR(30);

UPDATE ct_imaging_analysis
SET data_quality_flag =
    CASE
        WHEN Scheduled_Time        < Order_Time        THEN 'Invalid'
        WHEN Arrival_Time          < Scheduled_Time    THEN 'Invalid'
        WHEN Scan_Start_Time       < Arrival_Time      THEN 'Invalid'
        WHEN Scan_End_Time         < Scan_Start_Time   THEN 'Invalid'
        WHEN Report_Start_Time     < Scan_End_Time     THEN 'Invalid'
        WHEN Report_Finalized_Time < Report_Start_Time THEN 'Invalid'
        ELSE 'Valid'
    END;

/* NULL-HANDLING NOTE
   Where Report_Finalized_Time is NULL the final comparison
   evaluates to NULL, not TRUE, so the CASE falls through to
   'Valid'. Those records are excluded separately by the
   IS NOT NULL condition in the view below. The two filters are
   deliberately independent: an exam with no finalized report is
   incomplete, not corrupt, and the distinction matters. */


-- Confirm the flag distribution
SELECT
    data_quality_flag,
    COUNT(*) AS records
FROM ct_imaging_analysis
GROUP BY data_quality_flag;


-- -------------------------------------------------------------
-- KPI-ready view — the single source of truth for Power BI
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ct_kpi_ready AS
SELECT *
FROM ct_imaging_analysis
WHERE Status = 'Completed'              -- exclude cancellations and no-shows
  AND data_quality_flag = 'Valid'       -- exclude chronologically impossible records
  AND Order_Time IS NOT NULL
  AND Report_Finalized_Time IS NOT NULL; -- exclude exams with no finalized report

/* WHY THE BI LAYER READS A VIEW, NOT A TABLE

   Power BI connects to vw_ct_kpi_ready only. Every business rule
   — de-duplication, standardization, validation, population
   definition, duration logic — is resolved in SQL before the data
   reaches the dashboard.

   The dashboard is therefore a presentation layer, and the
   definition of "a completed, valid, reportable exam" lives in
   one version-controlled place rather than being re-implemented
   in DAX. */


-- -------------------------------------------------------------
-- POPULATION RECONCILIATION
-- Documents exactly how 20,075 source rows become 18,981
-- analysed exams. Every exclusion is accounted for.
-- -------------------------------------------------------------
SELECT 'Raw records loaded'                AS step, COUNT(*) AS records FROM ct_imaging_raw
UNION ALL
SELECT 'After de-duplication',                        COUNT(*) FROM ct_imaging_clean
UNION ALL
SELECT 'Completed exams only',                        COUNT(*) FROM ct_imaging_analysis
       WHERE Status = 'Completed'
UNION ALL
SELECT 'Passing chronology validation',               COUNT(*) FROM ct_imaging_analysis
       WHERE Status = 'Completed' AND data_quality_flag = 'Valid'
UNION ALL
SELECT 'With finalized report (KPI population)',      COUNT(*) FROM vw_ct_kpi_ready;


-- Demand loss: exams ordered that never produced an image.
-- Invisible in turnaround metrics by construction, because
-- these exams have no completion timestamp — which is exactly
-- why it needs to be reported as its own KPI.
SELECT
    Status,
    COUNT(*)                                                     AS exams,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)             AS pct_of_orders
FROM ct_imaging_analysis
GROUP BY Status
ORDER BY exams DESC;

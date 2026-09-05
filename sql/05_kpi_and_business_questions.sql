/* =============================================================
   05 — KPIs AND BUSINESS QUESTIONS
   CT Imaging Turnaround Time & Radiology Workflow Analysis

   Purpose: answer the questions agreed at project kickoff.
   All queries read vw_ct_kpi_ready (18,981 completed, valid,
   reported exams).

   Deeper analysis — variance decomposition, confounding checks
   and tiered SLA — is in script 06.
   ============================================================= */

USE ct_imaging_analytics;


/* =============================================================
   HEADLINE KPIs
   ============================================================= */

-- KPI 1 — Volume
SELECT COUNT(*) AS completed_exams
FROM vw_ct_kpi_ready;


-- KPI 2 — Average turnaround time
SELECT ROUND(AVG(total_turnaround_min), 2) AS avg_tat_min
FROM vw_ct_kpi_ready;


/* KPI 3 — Median turnaround time
   Reported alongside the mean because turnaround distributions
   are right-skewed: a small number of very long exams pulls the
   mean above the typical patient experience. MySQL has no
   built-in median, so it is derived positionally. */
WITH ordered AS (
    SELECT
        total_turnaround_min,
        ROW_NUMBER() OVER (ORDER BY total_turnaround_min) AS rn,
        COUNT(*)    OVER ()                               AS total_count
    FROM vw_ct_kpi_ready
)
SELECT AVG(total_turnaround_min) AS median_tat_min
FROM ordered
WHERE rn IN (
    FLOOR((total_count + 1) / 2),
    CEIL ((total_count + 1) / 2)
);


/* KPI 4 — 90th percentile turnaround time
   The service-level tail. 90% of exams finalize within this
   time; the remaining 10% are what referring clinicians escalate
   about. A mean cannot expose this. */
WITH ranked AS (
    SELECT
        total_turnaround_min,
        ROW_NUMBER() OVER (ORDER BY total_turnaround_min) AS rn,
        COUNT(*)    OVER ()                               AS total_count
    FROM vw_ct_kpi_ready
)
SELECT total_turnaround_min AS p90_tat_min
FROM ranked
WHERE rn = CEIL(total_count * 0.90);


-- KPI 5 — Full distribution shape in one query
WITH ranked AS (
    SELECT
        total_turnaround_min,
        ROW_NUMBER() OVER (ORDER BY total_turnaround_min) AS rn,
        COUNT(*)    OVER ()                               AS n
    FROM vw_ct_kpi_ready
)
SELECT
    MAX(CASE WHEN rn = CEIL(n * 0.25) THEN total_turnaround_min END) AS p25_tat,
    MAX(CASE WHEN rn = CEIL(n * 0.50) THEN total_turnaround_min END) AS p50_tat,
    MAX(CASE WHEN rn = CEIL(n * 0.75) THEN total_turnaround_min END) AS p75_tat,
    MAX(CASE WHEN rn = CEIL(n * 0.90) THEN total_turnaround_min END) AS p90_tat,
    MAX(CASE WHEN rn = CEIL(n * 0.95) THEN total_turnaround_min END) AS p95_tat
FROM ranked;


/* =============================================================
   Q1 — Which workflow stage creates the greatest delay?

   NOTE: this ranks stages by AVERAGE duration only. A long but
   consistent stage is a fixed cost, not a source of unpredict-
   ability. Script 06 decomposes the VARIANCE, which is the
   analytically stronger answer.
   ============================================================= */

SELECT 'Order to Schedule'   AS workflow_stage, ROUND(AVG(order_to_schedule_min), 2)    AS avg_minutes FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Reporting Duration',                    ROUND(AVG(reporting_duration_min), 2)                 FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Schedule to Arrival',                   ROUND(AVG(schedule_to_arrival_min), 2)                FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Scan Duration',                         ROUND(AVG(scan_duration_min), 2)                      FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Scan to Report Start',                  ROUND(AVG(scan_to_report_start_min), 2)               FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Arrival to Scan',                       ROUND(AVG(arrival_to_scan_min), 2)                    FROM vw_ct_kpi_ready
ORDER BY avg_minutes DESC;


-- Same stages with spread, not just centre. A stage with a large
-- standard deviation is unpredictable regardless of its mean.
SELECT
    'Order to Schedule'  AS stage,
    ROUND(AVG(order_to_schedule_min), 1) AS avg_min,
    ROUND(STDDEV(order_to_schedule_min), 1) AS sd_min
FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Reporting Duration',   ROUND(AVG(reporting_duration_min), 1),   ROUND(STDDEV(reporting_duration_min), 1)   FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Schedule to Arrival',  ROUND(AVG(schedule_to_arrival_min), 1),  ROUND(STDDEV(schedule_to_arrival_min), 1)  FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Scan Duration',        ROUND(AVG(scan_duration_min), 1),        ROUND(STDDEV(scan_duration_min), 1)        FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Scan to Report Start', ROUND(AVG(scan_to_report_start_min), 1), ROUND(STDDEV(scan_to_report_start_min), 1) FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Arrival to Scan',      ROUND(AVG(arrival_to_scan_min), 1),      ROUND(STDDEV(arrival_to_scan_min), 1)      FROM vw_ct_kpi_ready
ORDER BY sd_min DESC;


/* =============================================================
   Q2 — Does priority influence how quickly an exam completes,
        and at which stage does the difference occur?
   ============================================================= */

SELECT
    COALESCE(Priority, 'Unknown')              AS priority,
    COUNT(*)                                   AS exams,
    ROUND(AVG(total_turnaround_min), 2)        AS avg_tat,
    ROUND(AVG(order_to_schedule_min), 2)       AS avg_order_to_schedule,
    ROUND(AVG(schedule_to_arrival_min), 2)     AS avg_schedule_to_arrival,
    ROUND(AVG(arrival_to_scan_min), 2)         AS avg_arrival_to_scan,
    ROUND(AVG(scan_duration_min), 2)           AS avg_scan_duration,
    ROUND(AVG(reporting_duration_min), 2)      AS avg_reporting_duration
FROM vw_ct_kpi_ready
GROUP BY COALESCE(Priority, 'Unknown')
ORDER BY avg_tat DESC;

/* Read: the STAT advantage is concentrated in order_to_schedule
   and reporting_duration. Scan duration is effectively identical
   across all priorities — the expected result, since escalation
   changes queue position, not image acquisition physics. */


/* =============================================================
   Q3 — Which CT exam types have the longest turnaround?
   ============================================================= */

SELECT
    Exam_Type,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat,
    ROUND(AVG(order_to_schedule_min), 2)    AS avg_order_to_schedule,
    ROUND(AVG(scan_duration_min), 2)        AS avg_scan_duration,
    ROUND(AVG(reporting_duration_min), 2)   AS avg_reporting_duration
FROM vw_ct_kpi_ready
GROUP BY Exam_Type
ORDER BY avg_tat DESC;


/* =============================================================
   Q4 — Which shift experiences the greatest delays?
   ============================================================= */

SELECT
    Shift,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat,
    ROUND(STDDEV(total_turnaround_min), 2)  AS sd_tat,
    ROUND(AVG(arrival_to_scan_min), 2)      AS avg_scan_wait,
    ROUND(AVG(reporting_duration_min), 2)   AS avg_reporting_duration
FROM vw_ct_kpi_ready
GROUP BY Shift
ORDER BY avg_tat DESC;


/* =============================================================
   Q5 — Scanner workload and performance

   Interpretation caution: differences here are small relative to
   the ~55 minute standard deviation of TAT. Script 06 tests
   whether they are operationally meaningful before any of them
   is treated as an action item.
   ============================================================= */

SELECT
    COALESCE(Scanner_ID, 'Unknown')         AS scanner_id,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat,
    ROUND(STDDEV(total_turnaround_min), 2)  AS sd_tat,
    ROUND(AVG(arrival_to_scan_min), 2)      AS avg_scan_wait,
    ROUND(AVG(scan_duration_min), 2)        AS avg_scan_duration
FROM vw_ct_kpi_ready
GROUP BY COALESCE(Scanner_ID, 'Unknown')
ORDER BY avg_tat DESC;


/* =============================================================
   Q6 — Radiologist reporting times
   ============================================================= */

SELECT
    Radiologist_ID,
    COUNT(*)                                AS exams,
    ROUND(AVG(reporting_duration_min), 2)   AS avg_reporting_min,
    ROUND(STDDEV(reporting_duration_min), 2) AS sd_reporting_min
FROM vw_ct_kpi_ready
GROUP BY Radiologist_ID
ORDER BY avg_reporting_min ASC;

/* Interpretation caution: a raw ranking does not adjust for case
   mix. A radiologist reading a higher share of CT Angiography
   will show a longer average for reasons of complexity, not
   performance. Never present this as a productivity league table
   without stratifying by exam type. */


/* =============================================================
   Q7 — Are ED exams processed faster than inpatient/outpatient?
   ============================================================= */

SELECT
    COALESCE(Patient_Setting, 'Unknown')    AS patient_setting,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat,
    ROUND(AVG(order_to_schedule_min), 2)    AS avg_order_to_schedule,
    ROUND(AVG(arrival_to_scan_min), 2)      AS avg_scan_wait
FROM vw_ct_kpi_ready
WHERE Patient_Setting IS NOT NULL
GROUP BY COALESCE(Patient_Setting, 'Unknown')
ORDER BY avg_tat DESC;


/* =============================================================
   Q8 — SLA compliance against a flat 120-minute target

   The 120-minute threshold is an ILLUSTRATIVE ASSUMPTION for this
   synthetic dataset, not a published clinical standard.

   A single flat target applied to routine outpatient imaging and
   emergency STAT imaging alike produces a compliance figure that
   is technically correct and practically uninformative. Script 06
   applies priority-appropriate targets instead.
   ============================================================= */

SELECT
    COUNT(*)                                                            AS total_exams,
    SUM(CASE WHEN total_turnaround_min <= 120 THEN 1 ELSE 0 END)        AS within_sla,
    SUM(CASE WHEN total_turnaround_min >  120 THEN 1 ELSE 0 END)        AS outside_sla,
    ROUND(100.0 * SUM(CASE WHEN total_turnaround_min <= 120 THEN 1 ELSE 0 END) / COUNT(*), 2)
                                                                        AS sla_compliance_pct
FROM vw_ct_kpi_ready;


-- Flat SLA broken out by priority — the first sign that a single
-- threshold is masking very different realities
SELECT
    COALESCE(Priority, 'Unknown')                                       AS priority,
    COUNT(*)                                                            AS exams,
    SUM(CASE WHEN total_turnaround_min <= 120 THEN 1 ELSE 0 END)        AS within_sla,
    SUM(CASE WHEN total_turnaround_min >  120 THEN 1 ELSE 0 END)        AS outside_sla,
    ROUND(100.0 * SUM(CASE WHEN total_turnaround_min <= 120 THEN 1 ELSE 0 END) / COUNT(*), 2)
                                                                        AS sla_compliance_pct
FROM vw_ct_kpi_ready
GROUP BY COALESCE(Priority, 'Unknown')
ORDER BY sla_compliance_pct ASC;


/* =============================================================
   Q9 — Day-of-week pattern
   ============================================================= */

SELECT
    DAYNAME(Order_Time)                     AS day_of_week,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat
FROM vw_ct_kpi_ready
GROUP BY DAYOFWEEK(Order_Time), DAYNAME(Order_Time)
ORDER BY DAYOFWEEK(Order_Time);


/* =============================================================
   Q10 — Hour-of-day demand and turnaround

   Caveat for this dataset: exam volume is close to uniform across
   all 24 hours, which no real radiology department exhibits. The
   turnaround pattern by hour is interpretable; the VOLUME pattern
   is a property of the synthetic generator and is not.
   ============================================================= */

SELECT
    HOUR(Order_Time)                        AS order_hour,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat,
    ROUND(AVG(order_to_schedule_min), 2)    AS avg_order_to_schedule,
    ROUND(AVG(reporting_duration_min), 2)   AS avg_reporting_duration
FROM vw_ct_kpi_ready
GROUP BY HOUR(Order_Time)
ORDER BY order_hour;


/* =============================================================
   Q11 — Monthly trend
   ============================================================= */

SELECT
    DATE_FORMAT(Order_Time, '%Y-%m')        AS order_month,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat
FROM vw_ct_kpi_ready
GROUP BY DATE_FORMAT(Order_Time, '%Y-%m')
ORDER BY order_month;

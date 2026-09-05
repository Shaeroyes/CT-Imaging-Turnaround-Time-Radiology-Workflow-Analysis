/* =============================================================
   06 — ADVANCED ANALYSIS
   CT Imaging Turnaround Time & Radiology Workflow Analysis

   Three questions that a mean-comparison cannot answer:

     A. Which stage drives the VARIATION in turnaround, not just
        the largest average?
     B. Is the apparent contrast-status effect real, or is it
        confounded by exam mix?
     C. Does a priority-appropriate SLA change the conclusion?

   These queries produce the findings reported in the README.
   ============================================================= */

USE ct_imaging_analytics;


/* =============================================================
   A. VARIANCE DECOMPOSITION — where does unpredictability live?
   =============================================================

   Ranking stages by average duration answers "where does the time
   go". It does not answer "why is one exam slow and another
   fast". A stage can be long but highly consistent, which makes
   it a fixed cost rather than a source of variability — and a
   fixed cost is not where improvement effort belongs.

   Because the six stages sum exactly to total turnaround, the
   variance of TAT decomposes additively across them:

       Var(TAT) = Σ Cov(stage_i, TAT)

   So each stage's share of total variance is:

       Cov(stage_i, TAT) / Var(TAT)

   and the shares sum to 100%.

   Computed from raw aggregates:
       Cov(x,y) = AVG(x*y) - AVG(x)*AVG(y)
       Var(y)   = AVG(y*y) - AVG(y)*AVG(y)
   ------------------------------------------------------------- */

WITH s AS (
    SELECT
        AVG(total_turnaround_min)                              AS m_tat,
        AVG(total_turnaround_min * total_turnaround_min)       AS m_tat2,

        AVG(order_to_schedule_min)                             AS m_ots,
        AVG(order_to_schedule_min    * total_turnaround_min)   AS m_ots_tat,

        AVG(schedule_to_arrival_min)                           AS m_sta,
        AVG(schedule_to_arrival_min  * total_turnaround_min)   AS m_sta_tat,

        AVG(arrival_to_scan_min)                               AS m_ats,
        AVG(arrival_to_scan_min      * total_turnaround_min)   AS m_ats_tat,

        AVG(scan_duration_min)                                 AS m_scan,
        AVG(scan_duration_min        * total_turnaround_min)   AS m_scan_tat,

        AVG(scan_to_report_start_min)                          AS m_str,
        AVG(scan_to_report_start_min * total_turnaround_min)   AS m_str_tat,

        AVG(reporting_duration_min)                            AS m_rep,
        AVG(reporting_duration_min   * total_turnaround_min)   AS m_rep_tat
    FROM vw_ct_kpi_ready
)
SELECT 'Order to Schedule'    AS workflow_stage,
       ROUND(m_ots, 1)                                             AS avg_minutes,
       ROUND(100 * m_ots / m_tat, 1)                               AS pct_of_avg_tat,
       ROUND(100 * (m_ots_tat  - m_ots  * m_tat) / (m_tat2 - m_tat * m_tat), 1) AS pct_of_tat_variance
FROM s
UNION ALL
SELECT 'Reporting Duration',   ROUND(m_rep, 1),  ROUND(100 * m_rep  / m_tat, 1),
       ROUND(100 * (m_rep_tat  - m_rep  * m_tat) / (m_tat2 - m_tat * m_tat), 1) FROM s
UNION ALL
SELECT 'Schedule to Arrival',  ROUND(m_sta, 1),  ROUND(100 * m_sta  / m_tat, 1),
       ROUND(100 * (m_sta_tat  - m_sta  * m_tat) / (m_tat2 - m_tat * m_tat), 1) FROM s
UNION ALL
SELECT 'Scan Duration',        ROUND(m_scan, 1), ROUND(100 * m_scan / m_tat, 1),
       ROUND(100 * (m_scan_tat - m_scan * m_tat) / (m_tat2 - m_tat * m_tat), 1) FROM s
UNION ALL
SELECT 'Scan to Report Start', ROUND(m_str, 1),  ROUND(100 * m_str  / m_tat, 1),
       ROUND(100 * (m_str_tat  - m_str  * m_tat) / (m_tat2 - m_tat * m_tat), 1) FROM s
UNION ALL
SELECT 'Arrival to Scan',      ROUND(m_ats, 1),  ROUND(100 * m_ats  / m_tat, 1),
       ROUND(100 * (m_ats_tat  - m_ats  * m_tat) / (m_tat2 - m_tat * m_tat), 1) FROM s
ORDER BY pct_of_tat_variance DESC;

/* RESULT

     Stage                  Avg min   % of TAT   % of VARIANCE
     Order to Schedule         56.8      32.0%         50.4%
     Reporting Duration        43.6      24.6%         35.4%
     Schedule to Arrival       33.7      19.0%         10.1%
     Scan Duration             22.7      12.8%          2.5%
     Scan to Report Start      10.1       5.7%          1.1%
     Arrival to Scan            8.0       4.5%          0.4%
                                                     ------
                                                     100.0%

   The variance shares sum to exactly 100%, which is the built-in
   check that the decomposition is correct: the six stages are
   mutually exclusive and sum to total turnaround, so their
   covariance shares must account for all of its variance.

   Order-to-schedule and reporting together explain 86% of the
   variation in total turnaround.

   The three stages inside the imaging suite — patient wait, scan
   acquisition, handoff to reporting — account for 24% of average
   turnaround and 4% of its variance. They are fast AND consistent.

   CONCLUSION: the scanner is not the constraint. Turnaround is
   decided before the patient arrives and after they leave.
   Capacity investment in imaging throughput would not move the
   headline metric. */


-- Supporting evidence: spread and tail by stage. The two
-- high-variance stages are also the two with the widest tails.
SELECT 'Order to Schedule' AS stage,
       ROUND(AVG(order_to_schedule_min), 1)    AS avg_min,
       ROUND(STDDEV(order_to_schedule_min), 1) AS sd_min,
       MAX(order_to_schedule_min)              AS max_min
FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Reporting Duration',   ROUND(AVG(reporting_duration_min), 1),   ROUND(STDDEV(reporting_duration_min), 1),   MAX(reporting_duration_min)   FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Schedule to Arrival',  ROUND(AVG(schedule_to_arrival_min), 1),  ROUND(STDDEV(schedule_to_arrival_min), 1),  MAX(schedule_to_arrival_min)  FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Scan Duration',        ROUND(AVG(scan_duration_min), 1),        ROUND(STDDEV(scan_duration_min), 1),        MAX(scan_duration_min)        FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Scan to Report Start', ROUND(AVG(scan_to_report_start_min), 1), ROUND(STDDEV(scan_to_report_start_min), 1), MAX(scan_to_report_start_min) FROM vw_ct_kpi_ready
UNION ALL
SELECT 'Arrival to Scan',      ROUND(AVG(arrival_to_scan_min), 1),      ROUND(STDDEV(arrival_to_scan_min), 1),      MAX(arrival_to_scan_min)      FROM vw_ct_kpi_ready
ORDER BY sd_min DESC;


/* =============================================================
   B. CONFOUNDING CHECK — is the contrast effect real?
   =============================================================

   Unadjusted, contrast-enhanced exams look 8.9 minutes slower.
   Before recommending anything about contrast workflow, test
   whether the difference survives stratification by exam type.
   ------------------------------------------------------------- */

-- B1. The unadjusted comparison (the misleading version)
SELECT
    COALESCE(Contrast_Status, 'Unknown')    AS contrast_status,
    COUNT(*)                                AS exams,
    ROUND(AVG(total_turnaround_min), 2)     AS avg_tat
FROM vw_ct_kpi_ready
GROUP BY COALESCE(Contrast_Status, 'Unknown')
ORDER BY avg_tat DESC;


-- B2. Why it is confounded: contrast use is not evenly spread
-- across exam types. It concentrates in the exam types that are
-- inherently slowest, so the aggregate is partly measuring
-- exam mix rather than contrast.
SELECT
    Exam_Type,
    COUNT(*)                                                                   AS exams,
    SUM(CASE WHEN Contrast_Status = 'Yes' THEN 1 ELSE 0 END)                   AS with_contrast,
    ROUND(100.0 * SUM(CASE WHEN Contrast_Status = 'Yes' THEN 1 ELSE 0 END)
          / COUNT(*), 1)                                                       AS pct_contrast,
    ROUND(AVG(total_turnaround_min), 1)                                        AS avg_tat
FROM vw_ct_kpi_ready
WHERE Contrast_Status IS NOT NULL
GROUP BY Exam_Type
ORDER BY pct_contrast DESC;


-- B3. The stratified comparison (the honest version)
SELECT
    Exam_Type,
    ROUND(AVG(CASE WHEN Contrast_Status = 'No'  THEN total_turnaround_min END), 1) AS avg_tat_no_contrast,
    ROUND(AVG(CASE WHEN Contrast_Status = 'Yes' THEN total_turnaround_min END), 1) AS avg_tat_with_contrast,
    ROUND(AVG(CASE WHEN Contrast_Status = 'Yes' THEN total_turnaround_min END)
        - AVG(CASE WHEN Contrast_Status = 'No'  THEN total_turnaround_min END), 1) AS difference_min,
    SUM(CASE WHEN Contrast_Status = 'No'  THEN 1 ELSE 0 END)                       AS n_no_contrast,
    SUM(CASE WHEN Contrast_Status = 'Yes' THEN 1 ELSE 0 END)                       AS n_with_contrast
FROM vw_ct_kpi_ready
WHERE Contrast_Status IS NOT NULL
GROUP BY Exam_Type
ORDER BY difference_min DESC;

/* RESULT

     Exam Type            No contrast   With contrast   Difference
     Extremity CT             170.9          181.3         +10.4
     Chest CT                 171.0          178.5          +7.6
     Abdomen/Pelvis CT        172.5          178.6          +6.1
     Spine CT                 172.2          178.0          +5.8
     Head CT                  172.3          176.2          +3.9
     CT Angiography           197.5          197.9          +0.3

   Contrast is used in ~72% of Angiography, Abdomen/Pelvis and
   Chest exams but only ~12% of Head, Spine and Extremity exams —
   and the high-contrast group contains the slowest exam types,
   which is the mechanism producing the confound.

   The effect collapses entirely within CT Angiography — the
   highest-contrast, highest-TAT exam type — where contrast makes
   no measurable difference at all.

   CONCLUSION: contrast status is not an independent driver of
   turnaround at the magnitude the aggregate implies. Recommending
   a contrast workflow intervention on the basis of the unadjusted
   8.9-minute gap would target a confound rather than a cause. */


/* =============================================================
   C. EFFECT SIZE — which differences are worth acting on?
   =============================================================

   With ~4,500 exams per scanner, a difference of a few minutes is
   statistically detectable and operationally irrelevant. Compare
   every observed spread against the standard deviation of TAT
   (~55 min) before treating it as an action item.
   ------------------------------------------------------------- */

WITH overall AS (
    SELECT
        AVG(total_turnaround_min)    AS grand_mean,
        STDDEV(total_turnaround_min) AS grand_sd
    FROM vw_ct_kpi_ready
),
by_scanner AS (
    SELECT
        COALESCE(Scanner_ID, 'Unknown')  AS segment,
        COUNT(*)                         AS exams,
        AVG(total_turnaround_min)        AS avg_tat
    FROM vw_ct_kpi_ready
    GROUP BY COALESCE(Scanner_ID, 'Unknown')
)
SELECT
    'Scanner'                                              AS factor,
    segment,
    exams,
    ROUND(avg_tat, 1)                                      AS avg_tat,
    ROUND(avg_tat - grand_mean, 1)                         AS diff_from_overall,
    -- Cohen's d: difference expressed in standard deviations.
    -- Below 0.2 is conventionally a negligible effect.
    ROUND((avg_tat - grand_mean) / grand_sd, 3)            AS effect_size_d
FROM by_scanner, overall
ORDER BY avg_tat DESC;


-- Same test for shift
WITH overall AS (
    SELECT AVG(total_turnaround_min) AS grand_mean,
           STDDEV(total_turnaround_min) AS grand_sd
    FROM vw_ct_kpi_ready
)
SELECT
    'Shift'                                     AS factor,
    Shift                                       AS segment,
    COUNT(*)                                    AS exams,
    ROUND(AVG(total_turnaround_min), 1)         AS avg_tat,
    ROUND(AVG(total_turnaround_min) - MAX(grand_mean), 1)  AS diff_from_overall,
    ROUND((AVG(total_turnaround_min) - MAX(grand_mean)) / MAX(grand_sd), 3) AS effect_size_d
FROM vw_ct_kpi_ready, overall
GROUP BY Shift
ORDER BY avg_tat DESC;

/* RESULT

     Scanner: CT-02 173.8 -> CT-03 181.9. An 8.1 minute spread
     against SD 55.1, with d from -0.064 to +0.082. Statistically
     detectable at this sample size, operationally negligible.
     CONCLUSION: scanner is NOT an action item. Recommending an
     investigation into CT-03 would spend department effort on
     noise.

     Shift: Day 170.2 -> Night 182.3. A 12.1 minute spread
     (d ~0.11). Real and consistent, worth monitoring, but small
     against the 33.5 minutes available from priority handling.

   Reporting a non-finding is a deliberate analytical choice.
   Not every difference that reaches significance deserves an
   intervention. */


/* =============================================================
   D. TIERED SLA — a target that reflects clinical urgency
   =============================================================

   A flat 120-minute target returns 12.2% compliance, which reads
   as a department in crisis. It is not a useful measurement: it
   applies an emergency-grade expectation to routine outpatient
   imaging.

   Priority-appropriate targets below are ILLUSTRATIVE ASSUMPTIONS
   for this synthetic dataset. A real engagement would set them
   jointly with radiology and the emergency department.

       STAT    -> 60 minutes
       Urgent  -> 120 minutes
       Routine -> 240 minutes
   ------------------------------------------------------------- */

WITH tiered AS (
    SELECT
        Priority,
        total_turnaround_min,
        CASE Priority
            WHEN 'STAT'    THEN 60
            WHEN 'Urgent'  THEN 120
            WHEN 'Routine' THEN 240
        END AS sla_target_min
    FROM vw_ct_kpi_ready
    WHERE Priority IS NOT NULL
)
SELECT
    Priority,
    MAX(sla_target_min)                                                 AS target_min,
    COUNT(*)                                                            AS exams,
    ROUND(AVG(total_turnaround_min), 1)                                 AS avg_tat,
    SUM(CASE WHEN total_turnaround_min <= sla_target_min THEN 1 ELSE 0 END) AS within_sla,
    ROUND(100.0 * SUM(CASE WHEN total_turnaround_min <= sla_target_min THEN 1 ELSE 0 END)
          / COUNT(*), 1)                                                AS compliance_pct
FROM tiered
GROUP BY Priority
ORDER BY compliance_pct ASC;


-- Blended compliance across all priorities under tiered targets
WITH tiered AS (
    SELECT
        total_turnaround_min,
        CASE Priority
            WHEN 'STAT'    THEN 60
            WHEN 'Urgent'  THEN 120
            WHEN 'Routine' THEN 240
        END AS sla_target_min
    FROM vw_ct_kpi_ready
    WHERE Priority IS NOT NULL
)
SELECT
    COUNT(*)                                                                AS exams,
    ROUND(100.0 * SUM(CASE WHEN total_turnaround_min <= sla_target_min THEN 1 ELSE 0 END)
          / COUNT(*), 1)                                                    AS tiered_compliance_pct,
    ROUND(100.0 * SUM(CASE WHEN total_turnaround_min <= 120 THEN 1 ELSE 0 END)
          / COUNT(*), 1)                                                    AS flat_120_compliance_pct
FROM tiered;

/* RESULT

     Priority   Target   Compliance
     STAT        60 min      0.5%
     Urgent     120 min     13.7%
     Routine    240 min     85.7%
     Blended                51.2%   (vs 12.2% under a flat 120)

   The tiered view relocates the problem precisely. Routine
   imaging is largely meeting a reasonable expectation. Urgent and
   STAT imaging are not.

   CONCLUSION: the department's issue is not general slowness. It
   is that clinical urgency is not translating into sufficiently
   compressed turnaround at the top of the priority scale — which
   points back to finding A, since the STAT advantage that does
   exist comes almost entirely from faster scheduling. */


/* =============================================================
   E. WHERE SLA BREACHES ACCUMULATE

   For exams that miss the flat 120-minute target, which stage is
   responsible? Compares stage durations for breached vs met.
   ============================================================= */

SELECT
    CASE WHEN total_turnaround_min <= 120 THEN 'Within SLA' ELSE 'Breached SLA' END AS sla_status,
    COUNT(*)                                     AS exams,
    ROUND(AVG(total_turnaround_min), 1)          AS avg_tat,
    ROUND(AVG(order_to_schedule_min), 1)         AS avg_order_to_schedule,
    ROUND(AVG(schedule_to_arrival_min), 1)       AS avg_schedule_to_arrival,
    ROUND(AVG(arrival_to_scan_min), 1)           AS avg_arrival_to_scan,
    ROUND(AVG(scan_duration_min), 1)             AS avg_scan_duration,
    ROUND(AVG(scan_to_report_start_min), 1)      AS avg_scan_to_report,
    ROUND(AVG(reporting_duration_min), 1)        AS avg_reporting_duration
FROM vw_ct_kpi_ready
GROUP BY CASE WHEN total_turnaround_min <= 120 THEN 'Within SLA' ELSE 'Breached SLA' END;

/* RESULT

     SLA status   TAT    O->S   S->A   A->Scan  Scan   S->R   Report
     Within SLA   104.4   22.3   24.0     7.5   19.4    8.5    20.2
     Breached     187.5   61.6   35.1     8.1   23.1   10.3    46.8
     Difference   +83.1  +39.3  +11.1    +0.6   +3.7   +1.8   +26.6

   Read across the row: 79% of the 83-minute gap between a
   compliant exam and a breached one is created by just two
   stages — order-to-schedule (+39.3) and reporting (+26.6).

   Arrival-to-scan differs by 0.6 minutes between the two groups.
   The imaging suite performs essentially identically whether an
   exam meets its target or misses it by an hour.

   This corroborates the variance decomposition in section A
   through an entirely independent route, and is further evidence
   that imaging throughput is not the constraint. */

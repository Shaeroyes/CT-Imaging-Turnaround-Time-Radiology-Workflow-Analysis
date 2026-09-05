/* =============================================================
   02 — DATA PROFILING
   CT Imaging Turnaround Time & Radiology Workflow Analysis

   Purpose: measure the condition of the data BEFORE changing any
   of it. Nothing here modifies a table.

   Principle: profile first, clean second. Every cleaning decision
   in script 03 is justified by a result produced here.
   ============================================================= */

USE ct_imaging_analytics;


/* -------------------------------------------------------------
   1. VOLUME AND UNIQUENESS
   ------------------------------------------------------------- */

-- Expected: 20,075 rows / 20,000 unique -> 75 duplicate records
SELECT
    COUNT(*)                           AS total_records,
    COUNT(DISTINCT Exam_ID)            AS unique_exam_ids,
    COUNT(*) - COUNT(DISTINCT Exam_ID) AS duplicate_record_count
FROM ct_imaging_raw;


-- Which Exam_IDs are duplicated, and how many times
SELECT
    Exam_ID,
    COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Exam_ID
HAVING COUNT(*) > 1
ORDER BY record_count DESC;


-- Count of distinct Exam_IDs affected
SELECT COUNT(*) AS duplicated_exam_ids
FROM (
    SELECT Exam_ID
    FROM ct_imaging_raw
    GROUP BY Exam_ID
    HAVING COUNT(*) > 1
) AS d;


-- Inspect a duplicated pair in full to decide which row to keep.
-- If the rows are identical the duplicate is a load artefact;
-- if they differ, a retention rule is required.
SELECT r.*
FROM ct_imaging_raw r
JOIN (
    SELECT Exam_ID
    FROM ct_imaging_raw
    GROUP BY Exam_ID
    HAVING COUNT(*) > 1
    LIMIT 3
) d ON r.Exam_ID = d.Exam_ID
ORDER BY r.Exam_ID, r.Order_Time;


/* -------------------------------------------------------------
   2. COMPLETENESS — missing values by column
   -------------------------------------------------------------
   Result:
     Report_Finalized_Time  60
     Contrast_Status       119
     Patient_Setting        80
     Scanner_ID             80
     Priority               59
     all other columns       0
   ------------------------------------------------------------- */

SELECT
    SUM(Exam_ID               IS NULL) AS missing_exam_id,
    SUM(Patient_ID            IS NULL) AS missing_patient_id,
    SUM(Order_Time            IS NULL) AS missing_order_time,
    SUM(Scheduled_Time        IS NULL) AS missing_scheduled_time,
    SUM(Arrival_Time          IS NULL) AS missing_arrival_time,
    SUM(Scan_Start_Time       IS NULL) AS missing_scan_start,
    SUM(Scan_End_Time         IS NULL) AS missing_scan_end,
    SUM(Report_Start_Time     IS NULL) AS missing_report_start,
    SUM(Report_Finalized_Time IS NULL) AS missing_report_finalized,
    SUM(Exam_Type             IS NULL) AS missing_exam_type,
    SUM(Priority              IS NULL) AS missing_priority,
    SUM(Patient_Setting       IS NULL) AS missing_patient_setting,
    SUM(Scanner_ID            IS NULL) AS missing_scanner,
    SUM(Shift                 IS NULL) AS missing_shift,
    SUM(Contrast_Status       IS NULL) AS missing_contrast,
    SUM(Status                IS NULL) AS missing_status,
    SUM(Radiologist_ID        IS NULL) AS missing_radiologist,
    SUM(Technologist_ID       IS NULL) AS missing_technologist
FROM ct_imaging_raw;


-- Is missingness random, or concentrated in one segment?
-- If a field is missing far more often on one shift or scanner,
-- that points at a specific capture process rather than noise.
SELECT
    Shift,
    COUNT(*)                                                   AS exams,
    SUM(Priority IS NULL)                                      AS missing_priority,
    ROUND(100 * SUM(Priority IS NULL) / COUNT(*), 2)           AS pct_missing_priority,
    SUM(Contrast_Status IS NULL)                               AS missing_contrast,
    ROUND(100 * SUM(Contrast_Status IS NULL) / COUNT(*), 2)    AS pct_missing_contrast
FROM ct_imaging_raw
GROUP BY Shift
ORDER BY Shift;


/* -------------------------------------------------------------
   3. CONSISTENCY — category value audit
   -------------------------------------------------------------
   This is where casing and whitespace defects surface.

   Priority returns SIX distinct values for three real categories:
       'Routine', 'routine', 'Urgent', 'URGENT', 'STAT', 'Stat'
   Contrast_Status returns FOUR for two:
       'Yes', 'YES', 'No', 'No ' (trailing space)

   Left uncorrected, every GROUP BY in the analysis would split
   these into separate rows and understate each category.
   ------------------------------------------------------------- */

SELECT Priority, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Priority
ORDER BY record_count DESC;

SELECT Contrast_Status, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Contrast_Status
ORDER BY record_count DESC;

SELECT Status, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Status
ORDER BY record_count DESC;

SELECT Exam_Type, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Exam_Type
ORDER BY record_count DESC;

SELECT Scanner_ID, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Scanner_ID
ORDER BY record_count DESC;

SELECT Shift, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Shift
ORDER BY record_count DESC;

SELECT Patient_Setting, COUNT(*) AS record_count
FROM ct_imaging_raw
GROUP BY Patient_Setting
ORDER BY record_count DESC;


-- Explicitly expose whitespace defects, which are invisible in
-- a normal result grid
SELECT
    CONCAT('[', Contrast_Status, ']') AS raw_value_bracketed,
    LENGTH(Contrast_Status)           AS char_length,
    COUNT(*)                          AS record_count
FROM ct_imaging_raw
WHERE Contrast_Status IS NOT NULL
GROUP BY Contrast_Status
ORDER BY record_count DESC;


/* -------------------------------------------------------------
   4. VALIDITY — workflow chronology tests
   -------------------------------------------------------------
   The CT workflow must occur in a fixed order:

     Order -> Schedule -> Arrival -> Scan Start -> Scan End
           -> Report Start -> Report Finalized

   Any inversion is physically impossible and indicates a
   corrupted record.

   Result:
       Scheduled_Time    before Order_Time       35
       Scan_End_Time     before Scan_Start_Time  80
       Report_Start_Time before Scan_End_Time    60
   ------------------------------------------------------------- */

SELECT
    SUM(Scheduled_Time        < Order_Time)        AS schedule_before_order,
    SUM(Arrival_Time          < Scheduled_Time)    AS arrival_before_schedule,
    SUM(Scan_Start_Time       < Arrival_Time)      AS scan_before_arrival,
    SUM(Scan_End_Time         < Scan_Start_Time)   AS scan_end_before_start,
    SUM(Report_Start_Time     < Scan_End_Time)     AS report_start_before_scan_end,
    SUM(Report_Finalized_Time < Report_Start_Time) AS report_finalized_before_start
FROM ct_imaging_raw;


-- Distinct records failing at least one test (violations can
-- overlap, so this is not the sum of the columns above)
SELECT COUNT(*) AS records_failing_any_chronology_test
FROM ct_imaging_raw
WHERE Scheduled_Time        < Order_Time
   OR Arrival_Time          < Scheduled_Time
   OR Scan_Start_Time       < Arrival_Time
   OR Scan_End_Time         < Scan_Start_Time
   OR Report_Start_Time     < Scan_End_Time
   OR Report_Finalized_Time < Report_Start_Time;


-- Inspect examples before deciding how to handle them
SELECT
    Exam_ID, Order_Time, Scheduled_Time, Scan_Start_Time,
    Scan_End_Time, Report_Start_Time, Report_Finalized_Time
FROM ct_imaging_raw
WHERE Scan_End_Time < Scan_Start_Time
LIMIT 10;


/* -------------------------------------------------------------
   5. PLAUSIBILITY — value ranges
   -------------------------------------------------------------
   Chronologically valid values can still be implausible. This
   establishes whether extreme durations exist that would distort
   a mean.
   ------------------------------------------------------------- */

SELECT
    MIN(TIMESTAMPDIFF(MINUTE, Order_Time, Report_Finalized_Time)) AS min_tat_min,
    MAX(TIMESTAMPDIFF(MINUTE, Order_Time, Report_Finalized_Time)) AS max_tat_min,
    MIN(TIMESTAMPDIFF(MINUTE, Scan_Start_Time, Scan_End_Time))    AS min_scan_min,
    MAX(TIMESTAMPDIFF(MINUTE, Scan_Start_Time, Scan_End_Time))    AS max_scan_min
FROM ct_imaging_raw
WHERE Report_Finalized_Time IS NOT NULL;


/* -------------------------------------------------------------
   PROFILING SUMMARY
   -------------------------------------------------------------
     Duplicates              75 records      -> de-duplicate (03)
     Category inconsistency  Priority, Contrast -> standardize (03)
     Missing categoricals    338 values      -> retain as Unknown (03)
     Missing report time     60 records      -> retain NULL, exclude from TAT (04)
     Chronology violations   174 records     -> flag Invalid, exclude (04)

   No records are deleted. Defective records are flagged and
   excluded at the KPI layer so the exclusion remains auditable.
   ------------------------------------------------------------- */

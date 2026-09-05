/* =============================================================
   03 — CLEANING AND STANDARDIZATION
   CT Imaging Turnaround Time & Radiology Workflow Analysis

   Purpose: resolve the defects measured in script 02.

   Rules applied here:
     1. De-duplicate on Exam_ID, retaining the earliest order
     2. Standardize inconsistent category labels
     3. RETAIN records with missing categoricals — do not delete
     4. Do not correct or impute timestamps

   Records are never deleted for being defective. They are
   flagged in script 04 and excluded at the KPI layer, so every
   exclusion stays visible and auditable.
   ============================================================= */

USE ct_imaging_analytics;


DROP TABLE IF EXISTS ct_imaging_clean;

CREATE TABLE ct_imaging_clean AS

WITH ranked_data AS (
    /* De-duplication.
       75 Exam_IDs appear more than once. ROW_NUMBER partitioned
       by Exam_ID and ordered by Order_Time keeps the earliest
       record for each exam.

       Why earliest: the first order is the clinically originating
       event. A later duplicate is a re-entry artefact, and keeping
       it would restart the turnaround clock and understate TAT. */
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY Exam_ID
            ORDER BY Order_Time
        ) AS rn
    FROM ct_imaging_raw
)

SELECT
    Exam_ID,
    Patient_ID,

    -- Timestamps pass through untouched. Chronologically
    -- impossible values are NOT corrected here; inventing a
    -- timestamp would fabricate data. They are flagged in 04.
    Order_Time,
    Scheduled_Time,
    Arrival_Time,
    Scan_Start_Time,
    Scan_End_Time,
    Report_Start_Time,
    Report_Finalized_Time,

    Exam_Type,

    /* Priority standardization.
       Source contains six spellings of three categories:
         'Routine' / 'routine'
         'Urgent'  / 'URGENT'
         'STAT'    / 'Stat'
       Without this, every GROUP BY Priority would split each
       category across multiple rows and understate its volume. */
    CASE
        WHEN LOWER(TRIM(Priority)) = 'routine' THEN 'Routine'
        WHEN LOWER(TRIM(Priority)) = 'urgent'  THEN 'Urgent'
        WHEN LOWER(TRIM(Priority)) = 'stat'    THEN 'STAT'
        ELSE NULL   -- genuinely missing (59 records)
    END AS Priority,

    Patient_Setting,
    Scanner_ID,
    Shift,

    /* Contrast standardization.
       Source contains 'Yes', 'YES', 'No', and 'No ' with a
       trailing space. The trailing space is invisible in a
       result grid but produces a separate group. */
    CASE
        WHEN LOWER(TRIM(Contrast_Status)) = 'yes' THEN 'Yes'
        WHEN LOWER(TRIM(Contrast_Status)) = 'no'  THEN 'No'
        ELSE NULL   -- genuinely missing (119 records)
    END AS Contrast_Status,

    Status,
    Radiologist_ID,
    Technologist_ID

FROM ranked_data
WHERE rn = 1;


/* -------------------------------------------------------------
   VERIFICATION
   ------------------------------------------------------------- */

-- Expected: 20,000 rows, 20,000 unique Exam_IDs, zero duplicates
SELECT
    COUNT(*)                           AS total_records,
    COUNT(DISTINCT Exam_ID)            AS unique_exam_ids,
    COUNT(*) - COUNT(DISTINCT Exam_ID) AS remaining_duplicates
FROM ct_imaging_clean;


-- Priority should now return exactly three non-null categories
SELECT
    COALESCE(Priority, 'Unknown') AS priority,
    COUNT(*)                      AS record_count
FROM ct_imaging_clean
GROUP BY COALESCE(Priority, 'Unknown')
ORDER BY record_count DESC;


-- Contrast should now return exactly two non-null categories
SELECT
    COALESCE(Contrast_Status, 'Unknown') AS contrast_status,
    COUNT(*)                             AS record_count
FROM ct_imaging_clean
GROUP BY COALESCE(Contrast_Status, 'Unknown')
ORDER BY record_count DESC;


-- Confirm no records were lost in standardization: the count of
-- NULL Priority must equal the 59 measured in profiling, not more
SELECT
    SUM(Priority        IS NULL) AS null_priority,
    SUM(Contrast_Status IS NULL) AS null_contrast,
    SUM(Scanner_ID      IS NULL) AS null_scanner,
    SUM(Patient_Setting IS NULL) AS null_patient_setting
FROM ct_imaging_clean;


/* -------------------------------------------------------------
   NOTE ON MISSING CATEGORICALS

   Records with a missing Priority, Scanner_ID, Patient_Setting or
   Contrast_Status are RETAINED and surfaced downstream as
   'Unknown' rather than deleted.

   Deleting them would remove real completed examinations from
   volume counts and quietly bias every aggregate. Surfacing them
   as 'Unknown' keeps the exam in the denominator and makes the
   completeness gap visible in the dashboard instead of hiding it.

   Consequence to be aware of when reading the dashboard: 'Unknown'
   appears as a category in breakdown visuals. It is a data
   completeness indicator, not an operational segment, and should
   not be ranked against the real categories.
   ------------------------------------------------------------- */

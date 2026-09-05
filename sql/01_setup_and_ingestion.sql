/* =============================================================
   01 — DATABASE SETUP AND INGESTION
   CT Imaging Turnaround Time & Radiology Workflow Analysis

   Purpose: create the analytics database and load the synthetic
   source file WITHOUT losing any rows.

   Key design decision: a two-layer load.
     Layer 1  ct_imaging_raw_stage  — every column VARCHAR, so no
                                      row can be rejected on type
     Layer 2  ct_imaging_raw        — typed conversion under our
                                      own control, blanks -> NULL

   Why this matters is documented in the FAILED FIRST ATTEMPT
   section below.
   ============================================================= */


-- -------------------------------------------------------------
-- Create and select the database
-- -------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ct_imaging_analytics;

USE ct_imaging_analytics;


/* -------------------------------------------------------------
   FAILED FIRST ATTEMPT — retained deliberately as documentation
   -------------------------------------------------------------
   The original load declared the timestamp columns as DATETIME
   and imported the CSV directly:

       CREATE TABLE ct_imaging_raw (
           Exam_ID               VARCHAR(20),
           ...
           Report_Finalized_Time DATETIME,
           ...
       );

   The import wizard reported SUCCESS and loaded 20,015 rows.
   The source file contains 20,075.

   60 rows were silently discarded. Those records legitimately
   had a blank Report_Finalized_Time (the report was never
   finalized). Because the column was typed DATETIME, the import
   rejected the whole row rather than storing NULL.

   Consequence had this gone unnoticed:
       SELECT COUNT(*) FROM ct_imaging_raw
       WHERE Report_Finalized_Time IS NULL;   -->  0

   The missing-report rate would have appeared to be zero, because
   every record that would have proved otherwise had been dropped.

   Detected by reconciling the loaded row count against the source
   file row count. ALWAYS RUN THAT CHECK.
   ------------------------------------------------------------- */


-- -------------------------------------------------------------
-- LAYER 1 — Staging table
-- Every column is VARCHAR so that nothing can be rejected on
-- type conversion. Data quality problems are preserved here to
-- be measured, not silently dropped at the door.
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ct_imaging_raw_stage;

CREATE TABLE ct_imaging_raw_stage (
    Exam_ID               VARCHAR(50),
    Patient_ID            VARCHAR(50),
    Order_Time            VARCHAR(50),
    Scheduled_Time        VARCHAR(50),
    Arrival_Time          VARCHAR(50),
    Scan_Start_Time       VARCHAR(50),
    Scan_End_Time         VARCHAR(50),
    Report_Start_Time     VARCHAR(50),
    Report_Finalized_Time VARCHAR(50),
    Exam_Type             VARCHAR(100),
    Priority              VARCHAR(50),
    Patient_Setting       VARCHAR(50),
    Scanner_ID            VARCHAR(50),
    Shift                 VARCHAR(50),
    Contrast_Status       VARCHAR(50),
    Status                VARCHAR(50),
    Radiologist_ID        VARCHAR(50),
    Technologist_ID       VARCHAR(50)
);

/* IMPORT STEP (MySQL Workbench)
   Schemas pane -> ct_imaging_analytics -> Tables ->
   right-click ct_imaging_raw_stage -> Table Data Import Wizard
   -> select data/CT_Imaging_Raw_Data.csv
   -> confirm the first row is recognised as the column header.

   Command-line alternative:

       LOAD DATA LOCAL INFILE 'CT_Imaging_Raw_Data.csv'
       INTO TABLE ct_imaging_raw_stage
       FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
       LINES TERMINATED BY '\n'
       IGNORE 1 ROWS;
*/


-- -------------------------------------------------------------
-- INGESTION RECONCILIATION — do not skip
-- Expected: 20075. Anything less means rows were rejected.
-- -------------------------------------------------------------
SELECT COUNT(*) AS rows_loaded
FROM ct_imaging_raw_stage;

SELECT
    COUNT(*)                AS total_rows,
    COUNT(DISTINCT Exam_ID) AS unique_exam_ids
FROM ct_imaging_raw_stage;


-- -------------------------------------------------------------
-- LAYER 2 — Typed raw table
-- Conversion happens here, under explicit control:
--   * text fields trimmed; empty strings become NULL
--   * timestamps parsed from the first 19 characters, which
--     discards the sub-second precision in the source file
--   * blank Report_Finalized_Time is mapped to NULL rather than
--     causing the row to be rejected — this is the fix for the
--     failure described above
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ct_imaging_raw;

CREATE TABLE ct_imaging_raw AS
SELECT
    NULLIF(TRIM(Exam_ID), '')    AS Exam_ID,
    NULLIF(TRIM(Patient_ID), '') AS Patient_ID,

    STR_TO_DATE(LEFT(TRIM(Order_Time), 19),        '%Y-%m-%d %H:%i:%s') AS Order_Time,
    STR_TO_DATE(LEFT(TRIM(Scheduled_Time), 19),    '%Y-%m-%d %H:%i:%s') AS Scheduled_Time,
    STR_TO_DATE(LEFT(TRIM(Arrival_Time), 19),      '%Y-%m-%d %H:%i:%s') AS Arrival_Time,
    STR_TO_DATE(LEFT(TRIM(Scan_Start_Time), 19),   '%Y-%m-%d %H:%i:%s') AS Scan_Start_Time,
    STR_TO_DATE(LEFT(TRIM(Scan_End_Time), 19),     '%Y-%m-%d %H:%i:%s') AS Scan_End_Time,
    STR_TO_DATE(LEFT(TRIM(Report_Start_Time), 19), '%Y-%m-%d %H:%i:%s') AS Report_Start_Time,

    -- The fix: blank means "never finalized", not "invalid row"
    CASE
        WHEN TRIM(Report_Finalized_Time) = '' THEN NULL
        ELSE STR_TO_DATE(LEFT(TRIM(Report_Finalized_Time), 19), '%Y-%m-%d %H:%i:%s')
    END AS Report_Finalized_Time,

    NULLIF(TRIM(Exam_Type), '')       AS Exam_Type,
    NULLIF(TRIM(Priority), '')        AS Priority,
    NULLIF(TRIM(Patient_Setting), '') AS Patient_Setting,
    NULLIF(TRIM(Scanner_ID), '')      AS Scanner_ID,
    NULLIF(TRIM(Shift), '')           AS Shift,
    NULLIF(TRIM(Contrast_Status), '') AS Contrast_Status,
    NULLIF(TRIM(Status), '')          AS Status,
    NULLIF(TRIM(Radiologist_ID), '')  AS Radiologist_ID,
    NULLIF(TRIM(Technologist_ID), '') AS Technologist_ID

FROM ct_imaging_raw_stage;


-- -------------------------------------------------------------
-- Verify the conversion preserved every row
-- Expected: 20075 rows, 20000 unique exam IDs
-- The 75-row gap is the duplicate issue, addressed in script 03.
-- -------------------------------------------------------------
SELECT
    COUNT(*)                                  AS total_rows,
    COUNT(DISTINCT Exam_ID)                   AS unique_exam_ids,
    COUNT(*) - COUNT(DISTINCT Exam_ID)        AS duplicate_records
FROM ct_imaging_raw;

-- The 60 missing report timestamps now survive as NULL
SELECT COUNT(*) AS missing_report_finalized
FROM ct_imaging_raw
WHERE Report_Finalized_Time IS NULL;

SELECT
    MIN(Order_Time) AS earliest_order,
    MAX(Order_Time) AS latest_order
FROM ct_imaging_raw;

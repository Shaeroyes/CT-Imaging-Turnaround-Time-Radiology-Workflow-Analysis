# Build Walkthrough

How this project was built, in the order it was built, including the part that went wrong.

If you follow this end to end you will reproduce every number in the [README](../README.md) from the raw CSV. That is the point of writing it down. A portfolio project you cannot rebuild is a screenshot.

**Time needed:** around three hours the first time. Under an hour once you know the sequence.

---

## What you need

| Tool | Why |
|---|---|
| MySQL 8.0 or later | The analysis uses window functions, which arrived in 8.0 |
| MySQL Workbench | For the import wizard and running the scripts |
| Power BI Desktop | The dashboard |
| Excel | Independent validation of the KPIs |

Everything else is in this repository.

---

## Part 1. Look at the data before touching it

Open `data/CT_Imaging_Raw_Data.csv` in Excel and just read it for ten minutes. Not to analyse anything, only to understand what one row means.

One row is one CT examination. It carries seven timestamps that trace the exam from the moment a physician orders it to the moment a radiologist signs the report, plus the context you might use to explain why one exam took longer than another.

| Field | What it holds |
|---|---|
| `Exam_ID` | Unique identifier for the examination |
| `Patient_ID` | Synthetic patient identifier |
| `Order_Time` | When the exam was ordered |
| `Scheduled_Time` | When it was scheduled for |
| `Arrival_Time` | When the patient arrived |
| `Scan_Start_Time` | When scanning began |
| `Scan_End_Time` | When scanning ended |
| `Report_Start_Time` | When the radiologist began reading |
| `Report_Finalized_Time` | When the report was signed off |
| `Exam_Type` | Head, Chest, Abdomen/Pelvis, Spine, Extremity, CT Angiography |
| `Priority` | Routine, Urgent, STAT |
| `Patient_Setting` | ED, Inpatient, Outpatient |
| `Scanner_ID` | CT-01 through CT-04 |
| `Shift` | Day, Evening, Night |
| `Contrast_Status` | Yes, No |
| `Status` | Completed, Cancelled, No-show |
| `Radiologist_ID`, `Technologist_ID` | Who performed and read it |

**Then count the rows.** Not because it is interesting, but because you are about to need that number. Select column A and read the count at the bottom of the window, or press `Ctrl + End` to jump to the last row.

**20,075 rows. Write it down.**

That number is about to matter more than anything else on this page.

---

## Part 2. Load it into MySQL

### Create the database

Open MySQL Workbench, connect to your local server, and run:

```sql
CREATE DATABASE IF NOT EXISTS ct_imaging_analytics;
USE ct_imaging_analytics;
```

### The mistake worth making once

The obvious way to load this data is to create a table with sensible types, timestamps declared as `DATETIME`, and import straight into it.

Do that and the import wizard will tell you it succeeded. It will have loaded **20,015 rows**.

Sixty records will be gone, and nothing will say so.

Here is why. Sixty exams legitimately have a blank `Report_Finalized_Time`, because the report was never signed off. When the column is typed `DATETIME`, the import cannot store a blank, so instead of writing a null it discards the entire row.

Now think about what that costs you. Run this on the truncated table:

```sql
SELECT COUNT(*) FROM ct_imaging_raw
WHERE Report_Finalized_Time IS NULL;
```

It returns **zero**. A department with a flawless report completion rate. Every record capable of proving otherwise has already been deleted, by the tool you trusted to load them, in the exact dimension your analysis was going to measure.

You catch it by comparing the loaded row count against the source file. There is no other signal.

### The fix: load in two layers

**Layer one is a staging table where every column is text.** Nothing can be rejected on type, because there are no types to violate. Whatever is in the file gets in.

```sql
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
```

Now import into it:

1. In the **Schemas** pane on the left, expand `ct_imaging_analytics`, then **Tables**
2. Right click `ct_imaging_raw_stage` and choose **Table Data Import Wizard**
3. Browse to `data/CT_Imaging_Raw_Data.csv`
4. Choose **Use existing table**
5. **Confirm the first row is recognised as the column header.** If it is not, every column will be shifted by one row and you will spend an hour finding out why
6. Run it

> The wizard is slow on 20,000 rows. Two or three minutes is normal. Let it finish.

**Then run the check that matters:**

```sql
SELECT COUNT(*) AS rows_loaded FROM ct_imaging_raw_stage;
```

**It must say 20,075.** If it says anything else, stop and find out why before going any further. Nothing downstream is worth doing on a truncated table.

**Layer two is the typed conversion, under your control.** This is where blanks become nulls instead of becoming deleted rows:

```sql
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
```

`LEFT(..., 19)` trims the sub-second precision, which is noise you do not need. `NULLIF(TRIM(...), '')` turns empty strings into proper nulls so they can be counted rather than mistaken for real values.

Check again:

```sql
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT Exam_ID) AS unique_ids
FROM ct_imaging_raw;

SELECT COUNT(*) AS missing_report FROM ct_imaging_raw
WHERE Report_Finalized_Time IS NULL;
```

You should see **20,075 rows, 20,000 unique IDs, and 60 missing report timestamps**. All three of those are findings, not problems. The 75 row gap is the duplicate issue, handled in Part 4.

Everything above is in [`sql/01_setup_and_ingestion.sql`](../sql/01_setup_and_ingestion.sql).

---

## Part 3. Profile before you clean anything

This is the part most people skip, and it is the part that makes the rest defensible. Every cleaning decision you make in Part 4 should be traceable to something you measured here.

Run [`sql/02_data_profiling.sql`](../sql/02_data_profiling.sql) query by query rather than all at once, and actually read each result.

### Count what is missing

```sql
SELECT
    SUM(Priority        IS NULL) AS missing_priority,
    SUM(Patient_Setting IS NULL) AS missing_patient_setting,
    SUM(Scanner_ID      IS NULL) AS missing_scanner,
    SUM(Contrast_Status IS NULL) AS missing_contrast
FROM ct_imaging_raw;
```

**59, 80, 80, 119.** Three hundred and thirty eight blank values across four fields.

### Audit the categories

This is where the interesting defects hide:

```sql
SELECT Priority, COUNT(*) FROM ct_imaging_raw GROUP BY Priority;
```

Three real priorities. **Six rows come back.**

```
Routine    URGENT
routine    STAT
Urgent     Stat
```

Six spellings of three categories. Leave that alone and every `GROUP BY Priority` for the rest of the project splits each category across multiple rows and understates all of them. Your dashboard would show six priority bars for three priorities.

Contrast status is worse, because one of its defects is invisible:

```sql
SELECT
    CONCAT('[', Contrast_Status, ']') AS bracketed,
    LENGTH(Contrast_Status)           AS chars,
    COUNT(*)                          AS records
FROM ct_imaging_raw
WHERE Contrast_Status IS NOT NULL
GROUP BY Contrast_Status;
```

The brackets and the length are the trick. Without them, `No` and `No ` look identical in every result grid ever built. With them you can see that 107 records carry a trailing space and are being treated as a separate category.

### Test the chronology

A CT exam happens in a fixed physical order. Anything out of that order is impossible, not unusual, and means the record is corrupt.

```sql
SELECT
    SUM(Scheduled_Time    < Order_Time)      AS schedule_before_order,
    SUM(Scan_End_Time     < Scan_Start_Time) AS scan_end_before_start,
    SUM(Report_Start_Time < Scan_End_Time)   AS report_before_scan_end
FROM ct_imaging_raw;
```

**35, 80, 60.** These get flagged in Part 5, not repaired. There is no honest way to invent a timestamp.

---

## Part 4. Clean and standardize

Now, and only now, [`sql/03_cleaning_and_standardization.sql`](../sql/03_cleaning_and_standardization.sql).

Two things happen here.

### De-duplicate

```sql
WITH ranked_data AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY Exam_ID ORDER BY Order_Time) AS rn
    FROM ct_imaging_raw
)
SELECT ... FROM ranked_data WHERE rn = 1
```

`ROW_NUMBER()` numbers the rows inside each exam ID, ordered by order time, so the earliest row for every exam gets number one. Keeping only those removes the 75 duplicates.

Keep the earliest because the first order is the clinically originating event. A later duplicate is a re-entry, and keeping it would restart the turnaround clock and understate the time.

Then check your own assumption, which is the part worth doing:

```sql
SELECT r.* FROM ct_imaging_raw r
JOIN (SELECT Exam_ID FROM ct_imaging_raw
      GROUP BY Exam_ID HAVING COUNT(*) > 1 LIMIT 3) d
  ON r.Exam_ID = d.Exam_ID
ORDER BY r.Exam_ID;
```

All 75 pairs turn out identical across all 18 fields, and every pair shares the same order timestamp. They are load artefacts, not two competing versions of an exam. Which means the tie break is technically arbitrary and also completely safe, because either copy gives the same answer. Being able to say that in an interview is worth more than the de-duplication itself.

### Standardize the categories

```sql
CASE
    WHEN LOWER(TRIM(Priority)) = 'routine' THEN 'Routine'
    WHEN LOWER(TRIM(Priority)) = 'urgent'  THEN 'Urgent'
    WHEN LOWER(TRIM(Priority)) = 'stat'    THEN 'STAT'
    ELSE NULL
END AS Priority
```

`LOWER` handles the casing, `TRIM` handles the trailing space, and the `ELSE NULL` keeps genuinely missing values missing rather than silently inventing a category for them.

**Records with missing categories are kept, not deleted.** They are real completed examinations. Dropping them would pull genuine exams out of every volume count and shift every average in a direction nobody could audit later.

Verify:

```sql
SELECT COUNT(*), COUNT(DISTINCT Exam_ID) FROM ct_imaging_clean;
```

**20,000 and 20,000.** No duplicates left.

---

## Part 5. Build the metrics and the KPI view

[`sql/04_metrics_and_quality_flags.sql`](../sql/04_metrics_and_quality_flags.sql) turns seven timestamps into six measurable stages.

```sql
CREATE TABLE ct_imaging_analysis AS
SELECT *,
    TIMESTAMPDIFF(MINUTE, Order_Time,        Scheduled_Time)        AS order_to_schedule_min,
    TIMESTAMPDIFF(MINUTE, Scheduled_Time,    Arrival_Time)          AS schedule_to_arrival_min,
    TIMESTAMPDIFF(MINUTE, Arrival_Time,      Scan_Start_Time)       AS arrival_to_scan_min,
    TIMESTAMPDIFF(MINUTE, Scan_Start_Time,   Scan_End_Time)         AS scan_duration_min,
    TIMESTAMPDIFF(MINUTE, Scan_End_Time,     Report_Start_Time)     AS scan_to_report_start_min,
    TIMESTAMPDIFF(MINUTE, Report_Start_Time, Report_Finalized_Time) AS reporting_duration_min,
    TIMESTAMPDIFF(MINUTE, Order_Time,        Report_Finalized_Time) AS total_turnaround_min
FROM ct_imaging_clean;
```

Measuring all six separately, rather than guessing which one matters, is the entire reason this project reaches a conclusion nobody expected.

> **One thing to know about `TIMESTAMPDIFF(MINUTE, ...)`.** It truncates toward zero, so 63 minutes 59 seconds becomes 63 minutes. Across a single interval that is about half a minute of bias, which does not matter. But because each of the six stages truncates separately while total turnaround truncates once, the stage averages sum to 174.9 against a measured 177.4. That 2.4 minute gap is expected, not an error, and you should be ready to explain it rather than discover it in an interview.

Then flag the impossible records:

```sql
ALTER TABLE ct_imaging_analysis ADD COLUMN data_quality_flag VARCHAR(30);

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
```

Flagged, not deleted. The exclusion stays countable and reversible.

### The view Power BI will read

```sql
CREATE OR REPLACE VIEW vw_ct_kpi_ready AS
SELECT * FROM ct_imaging_analysis
WHERE Status = 'Completed'
  AND data_quality_flag = 'Valid'
  AND Order_Time IS NOT NULL
  AND Report_Finalized_Time IS NOT NULL;
```

**This view is the most important design decision in the project.**

Power BI will connect to this and nothing else. De-duplication, standardization, validation, the population definition and all the duration logic are settled in SQL before a single number reaches the dashboard.

The dashboard shows. SQL decides. It means "a completed, valid, reportable exam" is defined once, in version control, instead of being reinvented in DAX every time somebody builds a new visual.

Confirm where every row went:

```sql
SELECT 'Raw records loaded' AS step, COUNT(*) AS records FROM ct_imaging_raw
UNION ALL SELECT 'After de-duplication', COUNT(*) FROM ct_imaging_clean
UNION ALL SELECT 'Completed only', COUNT(*) FROM ct_imaging_analysis WHERE Status = 'Completed'
UNION ALL SELECT 'KPI population', COUNT(*) FROM vw_ct_kpi_ready;
```

**20,075 to 20,000 to 19,206 to 18,981.** Every excluded record accounted for.

Now run [`sql/05_kpi_and_business_questions.sql`](../sql/05_kpi_and_business_questions.sql) and [`sql/06_advanced_analysis.sql`](../sql/06_advanced_analysis.sql). Script 06 is where the variance decomposition, the confounding check and the tiered SLA live, which is the analysis that actually answers the question.

---

## Part 6. Connect Power BI

1. Open **Power BI Desktop**
2. **Get data**, then **More**
3. **Database** in the left pane, then **MySQL database**
4. Server: `localhost`
5. Database: `ct_imaging_analytics`
6. **OK**
7. Choose **Database** authentication and enter the username and password you set when installing MySQL. Usually `root` and whatever you chose then
8. In the Navigator, select **`vw_ct_kpi_ready`** and nothing else
9. **Load**

> **If MySQL does not appear in the connector list**, you need the MySQL Connector/NET package installed. Power BI will link you to it. Install, restart Power BI, and it will be there.

**Load the view, not the tables.** All the business rules are already in it. Loading the raw table would mean re-implementing every one of them in DAX.

### Rename it

In the **Data** pane, right click the table and rename it to **`Fact_CT_Exams`**. It is the fact table of the model, and calling it that makes every measure you write afterwards read like English.

---

## Part 7. Build the data model

### The problem you are about to hit

You will want a date table, and the relationship will refuse to work. The reason is that `Order_Time` is a datetime with a time component, and a date dimension has one row per day. They cannot join.

The fix is a calculated column that strips the time.

**Modeling** tab, **New column**, on `Fact_CT_Exams`:

```dax
Order Date = DATEVALUE(Fact_CT_Exams[Order_Time])
```

### Create the date table

**Modeling** tab, **New table**:

```dax
DateTable =
ADDCOLUMNS(
    CALENDAR(DATE(2025,1,1), DATE(2025,12,31)),
    "Year", YEAR([Date]),
    "Month Number", MONTH([Date]),
    "Month", FORMAT([Date], "MMM"),
    "Day", DAY([Date]),
    "Day Name", FORMAT([Date], "DDD"),
    "Day Number", WEEKDAY([Date], 2)
)
```

Then mark it as a date table: select `DateTable`, **Table tools**, **Mark as date table**, and choose the `Date` column. Time intelligence will not behave correctly until you do.

> **Sort the month names properly.** Select the `Month` column, then **Column tools**, **Sort by column**, and choose `Month Number`. Skip this and your monthly trend chart runs April, August, December, February, which looks broken because it is.

### Join them

**Modeling** tab, **Manage relationships**, **New**:

| Setting | Value |
|---|---|
| From | `DateTable` [Date] |
| To | `Fact_CT_Exams` [Order Date] |
| Cardinality | One to many |
| Cross filter direction | Single |
| Make active | Yes |

`DateTable` is the one side, `Fact_CT_Exams` is the many side. One calendar day, many examinations.

### The workflow stages table

The stage comparison chart needs the six stages as rows, but they exist as six separate columns. A small disconnected table solves it.

**New table**:

```dax
WorkflowStages =
DATATABLE(
    "Stage", STRING,
    "Sort", INTEGER,
    {
        {"Order to Schedule", 1},
        {"Schedule to Arrival", 2},
        {"Arrival to Scan", 3},
        {"Scan Duration", 4},
        {"Scan to Report", 5},
        {"Reporting Duration", 6}
    }
)
```

Leave it unrelated to everything else. It exists to give the chart an axis, and the measure in Part 8 does the rest.

### Handle the blanks

The SQL layer leaves missing categories as null, which is correct for analysis. For a dashboard you want them visible and labelled.

**Transform data** to open Power Query, then for `Priority`, `Scanner_ID`, `Patient_Setting` and `Contrast_Status`: right click the column header, **Replace values**, replace `null` with `Unknown`. **Close and apply**.

Now the gaps in the data appear as a category a viewer can see, rather than quietly vanishing from the totals. Add a note on the page saying what Unknown means, because otherwise someone will read it as a real operational segment.

---

## Part 8. Write the measures

All of these go on `Fact_CT_Exams`. **Modeling**, **New measure**, one at a time.

### Headline KPIs

```dax
Total Exams = COUNTROWS(Fact_CT_Exams)

Average TAT = AVERAGE(Fact_CT_Exams[total_turnaround_min])

Median TAT = MEDIAN(Fact_CT_Exams[total_turnaround_min])

P90 TAT = PERCENTILE.INC(Fact_CT_Exams[total_turnaround_min], 0.90)

Avg Scan Duration = AVERAGE(Fact_CT_Exams[scan_duration_min])

Avg Reporting Duration = AVERAGE(Fact_CT_Exams[reporting_duration_min])
```

Report the median and the 90th percentile next to the mean, always. Turnaround data leans right, so a handful of very slow exams pulls the average above what a typical patient experiences. The 90th percentile is the one a referring clinician actually cares about, because that is the exam they are chasing up the phone about.

### Stage measures

```dax
Avg Order to Schedule = AVERAGE(Fact_CT_Exams[order_to_schedule_min])
Avg Schedule to Arrival = AVERAGE(Fact_CT_Exams[schedule_to_arrival_min])
Avg Arrival to Scan = AVERAGE(Fact_CT_Exams[arrival_to_scan_min])
Avg Scan to Report = AVERAGE(Fact_CT_Exams[scan_to_report_start_min])
```

### The stage comparison measure

This is what makes the `WorkflowStages` table work:

```dax
Workflow Avg Minutes =
SWITCH(
    SELECTEDVALUE(WorkflowStages[Stage]),
    "Order to Schedule",   [Avg Order to Schedule],
    "Schedule to Arrival", [Avg Schedule to Arrival],
    "Arrival to Scan",     [Avg Arrival to Scan],
    "Scan Duration",       [Avg Scan Duration],
    "Scan to Report",      [Avg Scan to Report],
    "Reporting Duration",  [Avg Reporting Duration],
    BLANK()
)
```

Put `WorkflowStages[Stage]` on the axis of a bar chart and `[Workflow Avg Minutes]` as the value, and the six stages line up in one ranked visual instead of six unrelated cards. Because it reads through the same measures, it still responds to every slicer on the page.

### SLA measures

```dax
Exams Within SLA =
CALCULATE([Total Exams], Fact_CT_Exams[total_turnaround_min] <= 120)

SLA Compliance % =
DIVIDE([Exams Within SLA], [Total Exams])
```

Format that last one as a percentage: select the measure, **Measure tools**, **Format**, **Percentage**, one decimal place.

### Tiered SLA

The flat 120 minute target reports 12.2% compliance, which reads as a department in freefall. It holds routine outpatient imaging to an emergency standard. Priority appropriate targets tell a far more useful story.

Add a calculated column on `Fact_CT_Exams`:

```dax
SLA Target Minutes =
SWITCH(
    Fact_CT_Exams[Priority],
    "STAT", 60,
    "Urgent", 120,
    "Routine", 240,
    BLANK()
)
```

Then the measures:

```dax
Exams Within Tiered SLA =
CALCULATE(
    [Total Exams],
    FILTER(
        Fact_CT_Exams,
        NOT ISBLANK(Fact_CT_Exams[SLA Target Minutes])
            && Fact_CT_Exams[total_turnaround_min] <= Fact_CT_Exams[SLA Target Minutes]
    )
)

Exams With SLA Target =
CALCULATE([Total Exams], NOT ISBLANK(Fact_CT_Exams[SLA Target Minutes]))

Tiered SLA Compliance % =
DIVIDE([Exams Within Tiered SLA], [Exams With SLA Target])
```

Exams with a missing priority have no target, so they are excluded from both the numerator and the denominator rather than being counted as failures.

You should get **0.5% for STAT, 13.7% for Urgent, 85.7% for Routine, and 51.2% blended.** Same data, completely different conclusion.

---

## Part 9. Build the three pages

Three pages, each answering a different question. Every page carries the same six slicers across the top and the same KPI cards underneath, so a viewer never loses their place.

### Slicers and KPI cards on all three

Slicers: `Priority`, `Exam_Type`, `Patient_Setting`, `Scanner_ID`, `Shift`, `Contrast_Status`. Set each to **Dropdown** in the format pane so they do not eat half the canvas.

Cards: `Total Exams`, `Average TAT`, `Median TAT`, `P90 TAT`, `SLA Compliance %`, `Avg Reporting Duration`.

Build these once on page one, select them all, copy, and paste onto pages two and three. Identical position on every page.

> **Sync the slicers.** **View**, **Sync slicers**, then tick every page for each slicer. Without this, a viewer filters to STAT on page one, moves to page two, and silently sees all priorities again.

### Page 1, Executive Overview

The answer to "how are we doing".

| Visual | Setup |
|---|---|
| Average TAT by Priority | Bar chart. Axis `Priority`, value `[Average TAT]` |
| Average TAT by Exam Type | Bar chart. Axis `Exam_Type`, value `[Average TAT]` |
| Average TAT by Patient Setting | Bar chart. Axis `Patient_Setting`, value `[Average TAT]` |
| Turnaround trend | Line or area chart. Axis `DateTable[Month]`, value `[Average TAT]` |

Add a text box explaining the Unknown category. It is a data completeness indicator, not an operational segment, and without the note a reader will rank it against the real categories.

### Page 2, Workflow Analysis

The answer to "where is the time going". This is the page the whole project exists for.

| Visual | Setup |
|---|---|
| Average time by stage | Bar chart. Axis `WorkflowStages[Stage]`, value `[Workflow Avg Minutes]`, sorted descending |
| Workflow by priority | Matrix. Rows `Priority`, values the six stage measures |
| Scanner performance | Table. `Scanner_ID`, `[Total Exams]`, `[Average TAT]`, `[Avg Arrival to Scan]`, `[Avg Scan Duration]`, `[Avg Reporting Duration]` |

Add a text box with the finding stated plainly: order to schedule and reporting are the two largest stages, and together they account for around 100 minutes of the average workflow.

### Page 3, Operational Drivers

The answer to "what explains the differences".

| Visual | Setup |
|---|---|
| Average TAT by Shift | Bar chart |
| Average TAT by Contrast Status | Bar chart |
| Average TAT by Scanner | Bar chart |
| Average TAT by Hour of Day | Line chart. Axis `Order Hour`, value `[Average TAT]` |
| Exam volume by hour | Column chart. Axis `Order Hour`, value `[Total Exams]` |

For the hour axis you need a calculated column:

```dax
Order Hour = HOUR(Fact_CT_Exams[Order_Time])
```

> Volume by hour is nearly flat in this dataset, which no real radiology department looks like. It is an artefact of how the synthetic data was generated. Turnaround by hour is interpretable; volume by hour is not, and the limitations section says so.

### Navigation

Add three buttons across the top of each page. **Insert**, **Buttons**, **Blank**, then in the format pane set **Action** to **Page navigation** and pick the destination. Style the current page's button differently so a viewer always knows where they are.

> In Power BI Desktop you need **Ctrl + click** to follow a button. In the published report a single click works.

Save as `CT_Imaging_Dashboard.pbix`.

---

## Part 10. Validate it in Excel

Do not skip this. It is what turns "here are my numbers" into "here are my numbers and here is the proof they are right", and it is the part almost no portfolio project has.

Open [`analysis/CT_Imaging_Excel_Validation.xlsx`](../analysis/CT_Imaging_Excel_Validation.xlsx).

The workbook rebuilds every headline KPI from the raw CSV using live formulas, without reading any SQL output. It recalculates each stage duration from the timestamps, then rebuilds the KPIs, the variance decomposition, the segment breakdowns and the data quality checks on top of them.

**Every SQL versus Excel difference comes out at zero.**

Three details worth understanding, because they are the kind of thing an interviewer asks about:

**Matching MySQL's minute arithmetic.** The Excel formulas use `TRUNC(ROUND((end-start)*86400,0)/60)`, which converts to whole seconds, divides by 60, then truncates. Without mirroring the truncation the two systems would disagree by roughly half a minute on every KPI and the validation would fail for a reason unrelated to the analysis.

**`COUNTIF` is case-insensitive.** `COUNTIF(range,"URGENT")` also counts `Urgent`, so it would cheerfully report zero casing problems in a column full of them. The data quality sheet uses `SUMPRODUCT(--EXACT(range,"URGENT"))` instead, which is case-sensitive.

**The 2.4 minute gap.** The six stage averages sum to 174.9 while measured average turnaround is 177.4, because each stage truncates separately while the total truncates once. It is written on the sheet so the discrepancy has an answer rather than being a loose end.

---

## When something goes wrong

**The import loaded fewer rows than the file has.** You imported into a typed table. Go back to the staging table approach in Part 2.

**Every column is shifted by one.** The first row was not recognised as a header. Re-run the import wizard and check that setting.

**`GROUP BY Priority` returns six rows.** You are querying `ct_imaging_raw` instead of `ct_imaging_clean`. The standardization happens in Part 4.

**MySQL is missing from the Power BI connector list.** Install MySQL Connector/NET, then restart Power BI Desktop.

**The date relationship will not create.** `Order_Time` still has a time component. Create the `Order Date` calculated column in Part 7 first.

**The monthly chart is in alphabetical order.** Sort the `Month` column by `Month Number`, described in Part 7.

**A slicer filters one page but not the others.** Turn on **Sync slicers** under the View tab.

**Your numbers differ from the README in the second decimal place.** Check whether you are truncating minutes the way `TIMESTAMPDIFF` does. Without truncation, average turnaround comes out at 177.85 instead of 177.36.

---

## What you should be able to do now

Rebuild the whole thing from an empty schema, and explain why each step exists.

That second part is what matters. The sequence is not arbitrary: profiling comes before cleaning because cleaning something you have not measured is guessing. Timestamps get flagged rather than repaired because there is no honest way to invent one. The dashboard reads a view rather than a table because business rules belong in version control.

If someone opens this repository, points at any file, and asks what it does and why it exists, you should have an answer.

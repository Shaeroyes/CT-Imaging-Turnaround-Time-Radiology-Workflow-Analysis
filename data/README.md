# About this data

## Read this first

**`CT_Imaging_Raw_Data.csv` is synthetic. There are no real patients in it, no real clinicians, and no real hospital records.**

It was not derived from an actual health record system, not sampled from one, and not de-identified out of one. No protected health information was involved at any stage of this project, because there was none to involve.

The data was generated to behave like a real radiology department so that the analysis built on it would be a real analysis. That is the whole point of it existing.

## The generator

`generate_dataset.py` is the script that made it. Every parameter that shapes the output sits in one configuration block at the top: the exam mix, how often each exam type uses contrast, the distribution of every stage duration, and the exact count of every defect described below.

```bash
python generate_dataset.py --validate
```

**It does not overwrite `CT_Imaging_Raw_Data.csv`.** By default it writes to `CT_Imaging_Raw_Data_regenerated.csv`, alongside the original rather than on top of it. The analysis, the dashboard, and every number in the README came from the original file, and replacing it would quietly invalidate all of them. The generator is here to show how the data was made and to prove it is synthetic, not to be re-run before an analysis.

The `--validate` flag recomputes the headline statistics on whatever it just generated and prints them next to the original. A fresh random draw will never match exactly, but it should land close on all of them:

| Statistic | Original | Regenerated (seed 42) |
|---|---:|---:|
| Rows | 20,075 | 20,075 |
| Unique exam IDs | 20,000 | 20,000 |
| Average turnaround | 177.4 min | 178.7 min |
| Median turnaround | 169.0 min | 169.5 min |
| Average order to schedule | 57.3 min | 57.4 min |
| Average reporting | 44.1 min | 44.4 min |
| Average scan duration | 23.2 min | 23.2 min |

It also reproduces the finding the whole project rests on. Order-to-schedule comes out at 48.9% of turnaround variance and reporting at 35.6%, against 50.4% and 35.4% in the original. The structure is in the generator, not in one lucky draw.

### What the parameters encode

The numbers were chosen to make the data behave like a radiology department rather than like noise:

- **Scheduling and reporting are slow and highly variable.** Both are lognormal with long right tails, which is what produces the 86% of variance those two stages account for.
- **The scan itself is quick and consistent.** Arrival-to-scan and the handoff to reporting are uniform and tightly bounded, because a well-run imaging suite moves predictably.
- **Priority moves an exam up the queue without changing the scan.** It shifts order-to-schedule and reporting. It has no effect at all on scan duration, because escalating an exam does not make the scanner faster.
- **Contrast adds about seven minutes of acquisition,** and it is used far more often in the exam types that were already slow. That combination is what creates the confounding the analysis had to untangle.

## Why it was built broken on purpose

A clean dataset makes for a boring project and a dishonest one.

Real operational data arrives with duplicates nobody noticed, categories that three different people typed three different ways, blank fields where a workflow stopped early, and the occasional timestamp that claims a scan finished before it started. Handing that to an analyst is the job. Handing them something already tidy tests nothing.

So the defects below were built in deliberately, and every one of them was found by profiling before a single row was changed.

| What is wrong with it | How many | Where it gets handled |
|---|---:|---|
| The same `Exam_ID` appearing more than once | 75 | `sql/03` |
| `Priority` typed as `URGENT`, `routine`, `Stat` | 219 | `sql/03` |
| `Contrast_Status` typed as `YES` or `No` with a trailing space | 181 | `sql/03` |
| Blank `Contrast_Status` | 119 | `sql/03`, kept as `Unknown` |
| Blank `Scanner_ID` | 80 | `sql/03`, kept as `Unknown` |
| Blank `Patient_Setting` | 80 | `sql/03`, kept as `Unknown` |
| Blank `Report_Finalized_Time` | 60 | `sql/01`, and the cause of the silent ingestion failure |
| Blank `Priority` | 59 | `sql/03`, kept as `Unknown` |
| Scheduled before it was ordered | 35 | `sql/04`, flagged `Invalid` |
| Scan ended before it began | 80 | `sql/04`, flagged `Invalid` |
| Reporting started before the scan finished | 60 | `sql/04`, flagged `Invalid` |

The trailing space in `"No "` deserves a special mention. It is invisible in every result grid you will ever open, it looks exactly like `No`, and it silently splits one category into two in every grouped query you write. It was found by wrapping the value in brackets and checking its length, which is the only way anyone ever finds it.

The 60 blank report timestamps caused the most damage. Because the column had been declared `DATETIME` on the first load attempt, the import discarded those rows entirely rather than storing `NULL`, and reported success while doing it. The full story is in the root README and in `docs/data_quality_log.md`.

Sub-second precision in the source timestamps is truncated on load. See `sql/01`.

## What is in it

20,075 rows covering 1 January to 31 December 2025, one row per CT examination, 18 columns.

| Field | Type | What it holds |
|---|---|---|
| `Exam_ID` | text | Unique identifier for the examination |
| `Patient_ID` | text | Synthetic patient identifier |
| `Order_Time` | timestamp | When the exam was ordered |
| `Scheduled_Time` | timestamp | When it was scheduled for |
| `Arrival_Time` | timestamp | When the patient arrived |
| `Scan_Start_Time` | timestamp | When scanning began |
| `Scan_End_Time` | timestamp | When scanning ended |
| `Report_Start_Time` | timestamp | When the radiologist began reading |
| `Report_Finalized_Time` | timestamp | When the report was signed off |
| `Exam_Type` | text | Head, Chest, Abdomen/Pelvis, Spine, Extremity, or CT Angiography |
| `Priority` | text | Routine, Urgent, STAT |
| `Patient_Setting` | text | ED, Inpatient, Outpatient |
| `Scanner_ID` | text | CT-01 through CT-04 |
| `Shift` | text | Day, Evening, Night |
| `Contrast_Status` | text | Yes, No |
| `Status` | text | Completed, Cancelled, No-show |
| `Radiologist_ID` | text | Synthetic radiologist identifier |
| `Technologist_ID` | text | Synthetic technologist identifier |

Full field definitions are in `CT_Imaging_Data_Dictionary.xlsx`.

## Where the synthetic data shows its seams

Worth knowing, so nobody reads a generator artifact as an operational insight.

**Exam volume is almost perfectly flat across all 24 hours**, running between roughly 740 and 870 exams per hour whether it is 3 AM or 3 PM. No radiology department on earth looks like this. Turnaround by hour is meaningful and worth reading. Volume by hour is not, and the dashboard note says so.

**Scan duration varies by exam type but not by scanner.** Any scanner-level difference you find in this data is case mix and random variation, not equipment performance. This is exactly why the analysis reports the scanner comparison as a non-finding rather than an action item.

**Every relationship in here was generated rather than observed.** The analytical method carries over to real data without modification. The specific numbers do not carry over at all, and should never be quoted as though they describe a real department.



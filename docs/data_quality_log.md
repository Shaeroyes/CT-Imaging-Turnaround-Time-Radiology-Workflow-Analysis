# Data Quality Log

Every defect this dataset arrived with, how it was found, what was done about it, and why that was the right call.

Nothing here was discovered by accident. Profiling ran before a single row was changed, and every cleaning decision in `sql/03` and `sql/04` traces back to a measurement taken first.

---

## 1. The load that lied

**Severity: critical. Nothing reported an error.**

### What happened

The first import into MySQL brought in 20,015 rows. The source file has 20,075.

Sixty records were gone, and the import wizard said everything went fine.

The cause was one line in the table definition. `Report_Finalized_Time` had been declared `DATETIME`. Sixty exams legitimately had that field blank, because the report was never signed off. Rather than storing the blank as `NULL`, the import threw away the entire row.

### Why that mattered more than it looks

Run this on the truncated table:

```sql
SELECT COUNT(*) FROM ct_imaging_raw
WHERE Report_Finalized_Time IS NULL;
```

It returns zero.

Zero unfinalized reports. A department with a flawless completion rate. Every single record that could have proved otherwise had already been deleted by the tool that was supposed to load them, and it happened without a warning, a log line, or a failed row count on screen.

The dataset would have looked cleaner than it was. Not slightly cleaner. Cleaner in exactly the dimension the analysis needed to measure.

### How it surfaced

The loaded row count was compared against the source file. That is the only reason anyone knows about it. Nothing in the software's output gave it away.

### The fix

The load was rebuilt in two layers.

**Layer one, `ct_imaging_raw_stage`:** every column declared `VARCHAR`. Nothing can be rejected on type, because there are no types to violate. Whatever is in the file gets in.

**Layer two, `ct_imaging_raw`:** conversion happens here, under explicit control, using `STR_TO_DATE` with a `CASE` that maps blank strings to `NULL` instead of discarding the row.

All 20,075 rows now arrive, and the sixty missing report timestamps survive as `NULL` where they can be counted, reasoned about, and correctly excluded from turnaround metrics.

### What changed permanently

Row-count reconciliation now runs on every load, before anything downstream. See the checks at the end of `sql/01`.

It is the cheapest thing in the entire pipeline and it caught the most expensive problem in it.

---

## 2. Duplicates, 75 records

**How it was found:** `COUNT(*)` returned 20,075 while `COUNT(DISTINCT Exam_ID)` returned 20,000.

**What was done:** `ROW_NUMBER()` partitioned by `Exam_ID`, ordered by `Order_Time` ascending, keeping `rn = 1`.

**Why the earliest record:** the first order is the clinically originating event. A later duplicate is a re-entry artifact. Keeping it would restart the turnaround clock and understate TAT for every affected exam.

**Then something reassuring turned up.** All 75 pairs are identical across all 18 fields, and every pair shares the same `Order_Time`. These are not two competing versions of an exam. They are the same row written twice.

That has a useful consequence. The `ORDER BY Order_Time` tie-break is technically arbitrary, since every pair ties. It is also completely safe, because either copy produces the same answer. Worth knowing before someone asks how the tie was broken.

**Verified:** `ct_imaging_clean` holds 20,000 rows and 20,000 distinct `Exam_ID` values.

---

## 3. Categories spelled several ways

**How it was found:** grouping on each categorical column returned more distinct values than the field has real categories.

| Field | What was actually in there | Real categories |
|---|---|---:|
| `Priority` | `Routine`, `routine`, `Urgent`, `URGENT`, `STAT`, `Stat` | 3 |
| `Contrast_Status` | `Yes`, `YES`, `No`, `NO ` (trailing space) | 2 |

That trailing space is the interesting one. It is invisible in every result grid ever built, renders identically to `No`, and quietly creates a second category in every grouped query you write. It was confirmed by wrapping the value in brackets and measuring its length:

```sql
SELECT CONCAT('[', Contrast_Status, ']'), LENGTH(Contrast_Status), COUNT(*)
FROM ct_imaging_raw GROUP BY Contrast_Status;
```

**Why it mattered:** left alone, `GROUP BY Priority` would have returned six rows instead of three, splitting every category and understating all of them. The dashboard would have shown six priority bars for three priorities and nobody would necessarily have noticed.

**What was done:** `LOWER(TRIM(...))` normalization mapped to canonical labels in `sql/03`.

---

## 4. Missing categorical values, 338 in total

| Field | Blank |
|---|---:|
| `Contrast_Status` | 119 |
| `Scanner_ID` | 80 |
| `Patient_Setting` | 80 |
| `Priority` | 59 |

**What was done: kept them. All of them.**

The tempting move is to delete rows with missing fields. It makes the data tidier and it is quietly dishonest, because these are real completed examinations. Removing them pulls genuine exams out of every volume count and shifts every average, invisibly, in a direction nobody can audit later.

They appear instead as an explicit `Unknown` category. The exam stays in the denominator where it belongs, and the gap in the data becomes something a reader can see rather than something that silently moved the numbers.

Missingness was also checked against shift, to test whether it clustered in one capture process rather than being random.

**One consequence to be aware of.** `Unknown` shows up as a category in the dashboard breakdowns. It is a completeness indicator, not an operational segment, and it should never be ranked against the real categories or read as a finding. The dashboard carries a note saying exactly that.

---

## 5. Timestamps that run backwards, 174 records

The CT workflow happens in a fixed physical order:

```
Order → Schedule → Arrival → Scan Start → Scan End → Report Start → Report Finalized
```

Anything out of that order is impossible, not unusual. It means the record is corrupt.

The counts below are measured across the **full 20,000 record dataset**, before any filtering on exam status. That is the right population for a data quality audit, because a corrupt timestamp on a canceled exam is still a corrupt timestamp.

| Check | Failures |
|---|---:|
| `Scheduled_Time` before `Order_Time` | 35 |
| `Scan_End_Time` before `Scan_Start_Time` | 80 |
| `Report_Start_Time` before `Scan_End_Time` | 60 |
| `Arrival_Time` before `Scheduled_Time` | 0 |
| `Scan_Start_Time` before `Arrival_Time` | 0 |
| `Report_Finalized_Time` before `Report_Start_Time` | 0 |
| **Distinct records failing at least one check** | **174** |

The distinct count is lower than the column total because some records fail more than one check.

### Why the population flow shows 169, not 174

These two numbers describe different populations, and both are correct:

| Number | Population | What it counts |
|---|---|---:|
| **174** | All 20,000 de-duplicated records | Every record with a broken timestamp, whatever its status |
| **169** | The 19,206 completed exams only | The subset of those 174 that are also completed exams |

The five record difference is made up of **four no-shows and one canceled exam** that also carry chronology violations. Those five were already removed one step earlier, by the filter on completed exams, so they cannot be removed a second time by the chronology filter.

In the population flow in Section 6, each row shows what that step removed **from the records still remaining at that point**. The chronology step runs after the status filter, so it can only ever exclude the 169 that survived it.

Broken down by population, the per-check counts look like this:

| Check | All 20,000 records | Completed exams only |
|---|---:|---:|
| `Scheduled_Time` before `Order_Time` | 35 | 35 |
| `Scan_End_Time` before `Scan_Start_Time` | 80 | 76 |
| `Report_Start_Time` before `Scan_End_Time` | 60 | 59 |
| **Distinct records** | **174** | **169** |

One thing worth checking before anyone asks: none of the 75 removed duplicate copies carried a chronology violation, so the 174 figure is identical before and after de-duplication. De-duplication is not a third population to reconcile here.

**What was done: flagged `Invalid` with `data_quality_flag`, excluded from the KPI view. Not repaired, not deleted.**

**Why not repaired.** There is no honest way to invent a timestamp. Any correction would be a fabricated value dressed up as a measurement, and it would be indistinguishable from a real one six months later.

**Why not deleted.** Flagging keeps the exclusion auditable. The count is queryable at any time, the decision can be revisited, and the reasoning survives without anyone having to reload the source and reconstruct what happened.

---

## 6. Where all 20,075 rows ended up

Each row shows what that step removed from the records still remaining at that point, so the numbers are sequential rather than independent.

| Step | Records | Removed | Reason |
|---|---:|---:|---|
| Raw records loaded | 20,075 | | |
| After de-duplication | 20,000 | 75 | Repeated `Exam_ID` |
| Completed exams only | 19,206 | 794 | 400 canceled, 394 no-show |
| Passing chronology validation | 19,037 | 169 | Flagged `Invalid` |
| **With a finalized report** | **18,981** | 56 | Report never signed off |

Every excluded record is accounted for. No row disappears without a line explaining it.

The 169 here is the completed-exam subset of the 174 broken records counted in Section 5. Five of those 174 are no-shows or cancellations and were already removed by the previous step.

The 794 canceled and no-show exams are worth a second look. They cannot have a turnaround time, so they sit outside the KPIs by definition. But they are 3.97% of everything ordered, and they consumed booked scanner capacity to produce nothing clinical. That is a real operational cost that turnaround metrics are structurally incapable of seeing, which is exactly why it gets its own reporting line rather than being quietly filtered away.

One small trap worth flagging. The raw file contains 403 canceled exams; after de-duplication it is 400, because three of the 75 duplicates happened to be canceled records. A raw-file count and a post-cleaning count are different numbers, and quoting the wrong one is an easy mistake to make.

---

## 7. A note on minute arithmetic

`TIMESTAMPDIFF(MINUTE, ...)` truncates toward zero rather than rounding. Sixty-three minutes and fifty-nine seconds is sixty-three minutes.

Total turnaround is measured across a single interval, so the bias is roughly half a minute on a 177 minute metric. Immaterial at this scale.

It is documented anyway, for one specific reason: anyone who recomputes these numbers in Excel or Python without matching the truncation will get 177.85 instead of 177.36 and will reasonably wonder which one is wrong. Neither is. Now the discrepancy has an answer waiting for it instead of being a loose end.

The same truncation explains why the six stage averages sum to 174.9 while measured average turnaround is 177.4. Each stage truncates separately, so six half-minute roundings pile up, while total turnaround truncates once.

To measure without it:

```sql
TIMESTAMPDIFF(SECOND, Order_Time, Report_Finalized_Time) / 60
```

---

## The principles underneath all of this

**Profile before cleaning.** Every transformation should be justified by a measurement taken first. Cleaning something you have not measured is guessing.

**Reconcile row counts on every load.** The most damaging defect in this dataset raised no error and would have gone unnoticed forever.

**Flag, do not delete.** Excluding at the query layer keeps the exclusion visible, countable, and reversible.

**Never invent a timestamp.** A fabricated measurement is worse than a missing one, because you cannot tell it apart from a real one later.

**Show the gaps.** `Unknown` is more honest than a denominator that quietly got smaller.

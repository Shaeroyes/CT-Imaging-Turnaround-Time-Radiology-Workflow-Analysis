"""
Synthetic CT imaging dataset generator
=======================================

Builds the dataset this project analyses: 20,000 CT examinations across the
2025 calendar year, plus the data quality defects that were injected on
purpose so the cleaning work in sql/02 and sql/03 has something real to do.

THERE ARE NO REAL PATIENTS IN THE OUTPUT OF THIS SCRIPT. Every value is drawn
from a distribution. Nothing here was derived from, sampled from, or
de-identified out of an actual health record system.

--------------------------------------------------------------------------
IMPORTANT: this script does not overwrite the project dataset
--------------------------------------------------------------------------
By default it writes to CT_Imaging_Raw_Data_regenerated.csv, alongside the
original rather than on top of it. The analysis, the dashboard, and every
number in the README were produced from CT_Imaging_Raw_Data.csv, and
replacing that file would quietly invalidate all of them.

The generator is here to show how the data was made and to prove it is
synthetic, not to be re-run before an analysis.

    python generate_dataset.py                       # writes the _regenerated file
    python generate_dataset.py --out other.csv       # somewhere else
    python generate_dataset.py --seed 99             # a different draw
    python generate_dataset.py --validate            # compare against the original

--------------------------------------------------------------------------
How the workflow is modelled
--------------------------------------------------------------------------
Each exam gets an order timestamp, then six stage durations are drawn and
added on in sequence to produce the remaining six timestamps:

    Order -> Schedule -> Arrival -> Scan Start -> Scan End
          -> Report Start -> Report Finalized

The parameters below were chosen so the result behaves like a radiology
department: scheduling and reporting are slow and highly variable, the scan
itself is quick and consistent, priority moves an exam up the queue without
changing how long the scan takes, contrast adds acquisition time, and CT
Angiography is slower to acquire and slower to read than everything else.

Dependencies: pandas, numpy.
"""

import argparse
import numpy as np
import pandas as pd

# =========================================================================
# CONFIGURATION
# Everything that shapes the output lives here.
# =========================================================================

N_EXAMS = 20_000
YEAR = 2025
DEFAULT_SEED = 42

# ---- Reference data -----------------------------------------------------
RADIOLOGISTS = [f"RAD-{i:02d}" for i in range(1, 16)]    # 15 radiologists
TECHNOLOGISTS = [f"TECH-{i:02d}" for i in range(1, 21)]  # 20 technologists
PATIENT_POOL = [f"P{i}" for i in range(10_000, 18_000)]  # 8,000 patients

# ---- Categorical mixes --------------------------------------------------
EXAM_TYPES = {
    "Head CT":           0.2404,
    "Abdomen/Pelvis CT": 0.2217,
    "Chest CT":          0.2008,
    "CT Angiography":    0.1197,
    "Spine CT":          0.1174,
    "Extremity CT":      0.1001,
}

PRIORITIES = {"Routine": 0.5485, "Urgent": 0.3012, "STAT": 0.1503}

PATIENT_SETTINGS = {"ED": 0.3775, "Outpatient": 0.3512, "Inpatient": 0.2714}

SCANNERS = {"CT-01": 0.2770, "CT-04": 0.2505, "CT-02": 0.2433, "CT-03": 0.2293}

STATUSES = {"Completed": 0.9603, "Cancelled": 0.0200, "No-show": 0.0197}

# Contrast is clinically driven. Angiography, abdomen and chest studies use it
# routinely; head, spine and extremity studies mostly do not. This is what
# creates the confounding demonstrated in the analysis: the high-contrast
# group also contains the slowest exam types.
CONTRAST_RATE = {
    "CT Angiography":    0.7209,
    "Abdomen/Pelvis CT": 0.7147,
    "Chest CT":          0.7108,
    "Extremity CT":      0.1225,
    "Head CT":           0.1169,
    "Spine CT":          0.1144,
}

# Shift is a function of the hour the exam was ordered.
SHIFT_BY_HOUR = {h: ("Day" if 7 <= h <= 14 else "Evening" if 15 <= h <= 22 else "Night")
                 for h in range(24)}

# ---- Stage duration parameters -----------------------------------------
# Durations are lognormal unless stated otherwise, given as (mu, sigma) of the
# underlying normal, then clipped to a plausible range in minutes.
#
# Stage 1, Order to Schedule. The administrative queue, and the single
# largest source of variation in the finished dataset. Priority is what moves
# it: a STAT order is scheduled far faster than a routine one.
ORDER_TO_SCHEDULE = {                 # target mean / sd in minutes
    "Routine": (4.0103, 0.5467),      #  64.0 / 37.6
    "Urgent":  (3.7801, 0.6427),      #  53.8 / 38.1
    "STAT":    (3.3676, 0.8025),      #  40.0 / 37.0
}
ORDER_TO_SCHEDULE_CLIP = (5, 360)

# Stage 2, Schedule to Arrival. Patient-side lead time. ED patients are
# already in the building, so they arrive sooner than inpatients or outpatients.
SCHEDULE_TO_ARRIVAL = {
    "ED":         (3.2963, 0.5423),   #  31.3 / 18.3
    "Inpatient":  (3.4746, 0.4845),   #  36.3 / 18.7
    "Outpatient": (3.4760, 0.4750),   #  36.2 / 18.2
}
SCHEDULE_TO_ARRIVAL_CLIP = (5, 240)

# Stage 3, Arrival to Scan. Departmental wait. Uniform and tightly bounded:
# a well-run imaging suite takes patients through quickly and predictably.
ARRIVAL_TO_SCAN_RANGE = (2, 15)

# Stage 4, Scan Duration. Driven by what is being imaged, not by who is
# waiting. Angiography is the long one; contrast adds roughly seven minutes
# to any study. Priority deliberately has no effect here, because escalating
# an exam does not make the scanner faster.
SCAN_DURATION = {
    ("CT Angiography", False): (3.2748, 0.2527),   #  27.3 / 7.0
    ("CT Angiography", True):  (3.5020, 0.2026),   #  33.9 / 6.9
    ("other",          False): (2.8902, 0.3463),   #  19.1 / 6.8
    ("other",          True):  (3.2293, 0.2609),   #  26.1 / 6.9
}
SCAN_DURATION_CLIP = (5, 90)

# Stage 5, Scan End to Report Start. Handoff to the radiologist. Uniform and
# short.
SCAN_TO_REPORT_RANGE = (1, 20)

# Stage 6, Reporting Duration. The second big source of variation. Urgency
# pulls a study up the worklist, and angiography takes longer to read.
REPORTING_DURATION = {
    ("CT Angiography", "Routine"): (3.9255, 0.5008),   #  57.4 / 30.6
    ("CT Angiography", "Urgent"):  (3.8275, 0.5804),   #  54.3 / 34.1
    ("CT Angiography", "STAT"):    (3.6957, 0.6161),   #  48.7 / 32.8
    ("other",          "Routine"): (3.6075, 0.6422),   #  45.3 / 32.0
    ("other",          "Urgent"):  (3.4873, 0.6860),   #  41.3 / 31.6
    ("other",          "STAT"):    (3.2647, 0.7806),   #  35.4 / 31.7
}
REPORTING_DURATION_CLIP = (5, 300)

# ---- Data quality defects to inject ------------------------------------
# These are the whole reason this script matters. Handing an analyst a clean
# dataset tests nothing. Each defect below mirrors something that genuinely
# happens in hospital data extracts.
DEFECTS = {
    # Duplicate rows. Exact copies, which is what an extract that ran twice
    # actually produces. Appended at the end, so the file has 20,075 rows.
    "duplicate_rows": 75,

    # Free-text entry by different people over several years. Six spellings
    # of three real priorities, four spellings of two contrast values.
    "priority_lowercase": 121,   # 'routine'
    "priority_uppercase": 72,    # 'URGENT'
    "priority_titlecase": 26,    # 'Stat'
    "contrast_uppercase": 74,    # 'YES'
    "contrast_trailing_space": 107,  # 'No ' -- invisible in any result grid

    # Fields that were never filled in. Kept rather than deleted downstream,
    # because they belong to real completed examinations.
    "blank_priority": 59,
    "blank_patient_setting": 80,
    "blank_scanner": 80,
    "blank_contrast": 119,

    # Reports that were never signed off. These are the sixty records that
    # caused the silent ingestion failure documented in docs/data_quality_log.md:
    # a DATETIME column rejected every row with a blank here, and said nothing.
    "blank_report_finalized": 60,

    # Timestamps that violate the physical order of the workflow. Corrupt by
    # construction, flagged rather than repaired downstream, because there is
    # no honest way to invent a timestamp.
    "scheduled_before_order": 35,
    "scan_end_before_start": 80,
    "report_start_before_scan_end": 60,
}

COLUMNS = [
    "Exam_ID", "Patient_ID", "Order_Time", "Scheduled_Time", "Arrival_Time",
    "Scan_Start_Time", "Scan_End_Time", "Report_Start_Time", "Report_Finalized_Time",
    "Exam_Type", "Priority", "Patient_Setting", "Scanner_ID", "Shift",
    "Contrast_Status", "Status", "Radiologist_ID", "Technologist_ID",
]


# =========================================================================
# GENERATION
# =========================================================================

def _pick(rng, mapping, n):
    """Draw n values from a {value: probability} mapping."""
    keys = list(mapping)
    p = np.array([mapping[k] for k in keys], dtype=float)
    return rng.choice(keys, size=n, p=p / p.sum())


def _lognormal(rng, mu, sigma, clip):
    """One lognormal draw per element of mu, clipped to a plausible range."""
    values = rng.lognormal(mean=mu, sigma=sigma)
    return np.clip(values, clip[0], clip[1])


def generate_clean(n, seed):
    """Build n examinations with no defects in them yet."""
    rng = np.random.default_rng(seed)

    # --- Order timestamps, spread uniformly across the calendar year -----
    start = pd.Timestamp(f"{YEAR}-01-01")
    end = pd.Timestamp(f"{YEAR}-12-31 23:59:59")
    span = (end - start).total_seconds()
    order_time = start + pd.to_timedelta(rng.uniform(0, span, n), unit="s")
    order_time = pd.Series(order_time).sort_values().reset_index(drop=True)

    # --- Categorical attributes ------------------------------------------
    exam_type = _pick(rng, EXAM_TYPES, n)
    priority = _pick(rng, PRIORITIES, n)
    setting = _pick(rng, PATIENT_SETTINGS, n)
    scanner = _pick(rng, SCANNERS, n)
    status = _pick(rng, STATUSES, n)

    # Contrast depends on what is being scanned, not on chance alone.
    contrast = rng.random(n) < np.array([CONTRAST_RATE[e] for e in exam_type])

    shift = order_time.dt.hour.map(SHIFT_BY_HOUR).to_numpy()

    is_angio = exam_type == "CT Angiography"
    angio_key = np.where(is_angio, "CT Angiography", "other")

    # --- Stage durations, in minutes -------------------------------------
    mu = np.array([ORDER_TO_SCHEDULE[p][0] for p in priority])
    sg = np.array([ORDER_TO_SCHEDULE[p][1] for p in priority])
    order_to_schedule = _lognormal(rng, mu, sg, ORDER_TO_SCHEDULE_CLIP)

    mu = np.array([SCHEDULE_TO_ARRIVAL[s][0] for s in setting])
    sg = np.array([SCHEDULE_TO_ARRIVAL[s][1] for s in setting])
    schedule_to_arrival = _lognormal(rng, mu, sg, SCHEDULE_TO_ARRIVAL_CLIP)

    arrival_to_scan = rng.uniform(*ARRIVAL_TO_SCAN_RANGE, n)

    mu = np.array([SCAN_DURATION[(a, bool(c))][0] for a, c in zip(angio_key, contrast)])
    sg = np.array([SCAN_DURATION[(a, bool(c))][1] for a, c in zip(angio_key, contrast)])
    scan_duration = _lognormal(rng, mu, sg, SCAN_DURATION_CLIP)

    scan_to_report = rng.uniform(*SCAN_TO_REPORT_RANGE, n)

    mu = np.array([REPORTING_DURATION[(a, p)][0] for a, p in zip(angio_key, priority)])
    sg = np.array([REPORTING_DURATION[(a, p)][1] for a, p in zip(angio_key, priority)])
    reporting = _lognormal(rng, mu, sg, REPORTING_DURATION_CLIP)

    # --- Walk the durations forward into timestamps ----------------------
    mins = lambda x: pd.to_timedelta(x, unit="m")
    scheduled = order_time + mins(order_to_schedule)
    arrival = scheduled + mins(schedule_to_arrival)
    scan_start = arrival + mins(arrival_to_scan)
    scan_end = scan_start + mins(scan_duration)
    report_start = scan_end + mins(scan_to_report)
    report_final = report_start + mins(reporting)

    df = pd.DataFrame({
        "Exam_ID": [f"CT{100_000 + i}" for i in range(n)],
        "Patient_ID": rng.choice(PATIENT_POOL, size=n),
        "Order_Time": order_time,
        "Scheduled_Time": scheduled,
        "Arrival_Time": arrival,
        "Scan_Start_Time": scan_start,
        "Scan_End_Time": scan_end,
        "Report_Start_Time": report_start,
        "Report_Finalized_Time": report_final,
        "Exam_Type": exam_type,
        "Priority": priority,
        "Patient_Setting": setting,
        "Scanner_ID": scanner,
        "Shift": shift,
        "Contrast_Status": np.where(contrast, "Yes", "No"),
        "Status": status,
        "Radiologist_ID": rng.choice(RADIOLOGISTS, size=n),
        "Technologist_ID": rng.choice(TECHNOLOGISTS, size=n),
    })
    return df[COLUMNS], rng


# =========================================================================
# DEFECT INJECTION
# =========================================================================

def inject_defects(df, rng, report=True):
    """Make the dataset realistically broken, and say exactly how."""
    df = df.copy()
    n = len(df)
    log = []

    # Reserve disjoint sets of row indices so the counts come out exact and
    # one defect never lands on top of another.
    pool = rng.permutation(n).tolist()
    take = lambda k: [pool.pop() for _ in range(k)]

    # --- Inconsistent category spellings ---------------------------------
    for key, column, value in [
        ("priority_lowercase", "Priority", "routine"),
        ("priority_uppercase", "Priority", "URGENT"),
        ("priority_titlecase", "Priority", "Stat"),
    ]:
        canonical = {"routine": "Routine", "URGENT": "Urgent", "Stat": "STAT"}[value]
        candidates = [i for i in pool if df.at[i, "Priority"] == canonical]
        idx = candidates[:DEFECTS[key]]
        pool = [i for i in pool if i not in set(idx)]
        df.loc[idx, column] = value
        log.append((f"Priority written as '{value}'", len(idx)))

    for key, value, canonical in [
        ("contrast_uppercase", "YES", "Yes"),
        ("contrast_trailing_space", "No ", "No"),
    ]:
        candidates = [i for i in pool if df.at[i, "Contrast_Status"] == canonical]
        idx = candidates[:DEFECTS[key]]
        pool = [i for i in pool if i not in set(idx)]
        df.loc[idx, "Contrast_Status"] = value
        log.append((f"Contrast_Status written as '{value}'", len(idx)))

    # --- Fields never filled in -------------------------------------------
    for key, column in [
        ("blank_priority", "Priority"),
        ("blank_patient_setting", "Patient_Setting"),
        ("blank_scanner", "Scanner_ID"),
        ("blank_contrast", "Contrast_Status"),
        ("blank_report_finalized", "Report_Finalized_Time"),
    ]:
        idx = take(DEFECTS[key])
        df.loc[idx, column] = np.nan
        log.append((f"{column} left blank", len(idx)))

    # --- Timestamps that run backwards ------------------------------------
    # Each one is pushed behind the event it is supposed to follow. These are
    # impossible, not merely unusual, which is what makes them detectable.
    idx = take(DEFECTS["scheduled_before_order"])
    df.loc[idx, "Scheduled_Time"] = (
        df.loc[idx, "Order_Time"] - pd.to_timedelta(rng.uniform(5, 120, len(idx)), unit="m"))
    log.append(("Scheduled_Time before Order_Time", len(idx)))

    idx = take(DEFECTS["scan_end_before_start"])
    df.loc[idx, "Scan_End_Time"] = (
        df.loc[idx, "Scan_Start_Time"] - pd.to_timedelta(rng.uniform(1, 30, len(idx)), unit="m"))
    log.append(("Scan_End_Time before Scan_Start_Time", len(idx)))

    idx = take(DEFECTS["report_start_before_scan_end"])
    df.loc[idx, "Report_Start_Time"] = (
        df.loc[idx, "Scan_End_Time"] - pd.to_timedelta(rng.uniform(1, 45, len(idx)), unit="m"))
    log.append(("Report_Start_Time before Scan_End_Time", len(idx)))

    # --- Duplicate rows ----------------------------------------------------
    # Exact copies appended at the end, which is what a re-run extract
    # produces. Because they are identical in every field, whichever copy a
    # de-duplication rule keeps gives the same answer.
    dupes = df.iloc[rng.choice(n, size=DEFECTS["duplicate_rows"], replace=False)].copy()
    df = pd.concat([df, dupes], ignore_index=True)
    log.append(("Exact duplicate records appended", len(dupes)))

    if report:
        print("\nDefects injected")
        print("-" * 52)
        for label, count in log:
            print(f"  {label:<42} {count:>6,}")
        print("-" * 52)
        print(f"  {'Final row count':<42} {len(df):>6,}")

    return df


# =========================================================================
# VALIDATION
# =========================================================================

# Measured from the project dataset, CT_Imaging_Raw_Data.csv. A regenerated
# file is a fresh random draw, so it will not match these exactly. It should
# land close to all of them. Anything wildly off means a parameter has drifted.
EXPECTED = {
    "rows": 20_075,
    "unique_exam_ids": 20_000,
    "avg_turnaround_min": 177.4,
    "median_turnaround_min": 169.0,
    "p90_turnaround_min": 248.0,
    "avg_order_to_schedule": 57.3,
    "avg_reporting": 44.1,
    "avg_scan_duration": 23.2,
    "avg_arrival_to_scan": 8.5,
    "completed_share": 0.960,
}


def validate(df):
    """Recompute the headline statistics and compare them to the original."""
    d = df.drop_duplicates("Exam_ID", keep="first").copy()
    for c in COLUMNS[2:9]:
        d[c] = pd.to_datetime(d[c], errors="coerce")

    gap = lambda a, b: (d[b] - d[a]).dt.total_seconds() / 60
    d["ots"] = gap("Order_Time", "Scheduled_Time")
    d["ats"] = gap("Arrival_Time", "Scan_Start_Time")
    d["scan"] = gap("Scan_Start_Time", "Scan_End_Time")
    d["rep"] = gap("Report_Start_Time", "Report_Finalized_Time")
    d["tat"] = gap("Order_Time", "Report_Finalized_Time")

    invalid = (
        (d.Scheduled_Time < d.Order_Time) | (d.Arrival_Time < d.Scheduled_Time)
        | (d.Scan_Start_Time < d.Arrival_Time) | (d.Scan_End_Time < d.Scan_Start_Time)
        | (d.Report_Start_Time < d.Scan_End_Time)
        | (d.Report_Finalized_Time < d.Report_Start_Time)
    )
    k = d[(d.Status == "Completed") & (~invalid) & d.Report_Finalized_Time.notna()]

    actual = {
        "rows": len(df),
        "unique_exam_ids": df.Exam_ID.nunique(),
        "avg_turnaround_min": k.tat.mean(),
        "median_turnaround_min": k.tat.median(),
        "p90_turnaround_min": k.tat.quantile(0.9),
        "avg_order_to_schedule": k.ots.mean(),
        "avg_reporting": k.rep.mean(),
        "avg_scan_duration": k.scan.mean(),
        "avg_arrival_to_scan": k.ats.mean(),
        "completed_share": (d.Status == "Completed").mean(),
    }

    print("\nComparison against the project dataset")
    print("-" * 66)
    print(f"  {'Statistic':<28}{'Original':>12}{'Generated':>12}{'Diff':>12}")
    print("-" * 66)
    for key, want in EXPECTED.items():
        got = actual[key]
        print(f"  {key:<28}{want:>12,.2f}{got:>12,.2f}{got - want:>12,.2f}")
    print("-" * 66)
    print(f"  KPI-ready exams in the generated file: {len(k):,}")

    print("\n  Variance decomposition, the project's central finding")
    stages = [("Order to Schedule", "ots"), ("Reporting", "rep"),
              ("Scan duration", "scan"), ("Arrival to Scan", "ats")]
    total_var = k.tat.var()
    for label, col in stages:
        share = 100 * np.cov(k[col], k.tat)[0, 1] / total_var
        print(f"    {label:<22} {share:5.1f}% of turnaround variance")


# =========================================================================
# ENTRY POINT
# =========================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="CT_Imaging_Raw_Data_regenerated.csv",
                    help="output path (deliberately NOT the project dataset)")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED,
                    help=f"random seed (default {DEFAULT_SEED})")
    ap.add_argument("--rows", type=int, default=N_EXAMS,
                    help=f"unique examinations to generate (default {N_EXAMS:,})")
    ap.add_argument("--validate", action="store_true",
                    help="recompute the headline stats and compare to the original")
    args = ap.parse_args()

    print(f"Generating {args.rows:,} synthetic CT examinations (seed {args.seed})")
    clean, rng = generate_clean(args.rows, args.seed)
    df = inject_defects(clean, rng)

    df.to_csv(args.out, index=False)
    print(f"\nWritten to {args.out}")

    if args.validate:
        validate(df)

    print("\nReminder: this file is synthetic. No real patients, no real "
          "clinicians, no real hospital records.")


if __name__ == "__main__":
    main()

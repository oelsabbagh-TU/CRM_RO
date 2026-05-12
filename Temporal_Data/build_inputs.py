"""Build 192-timestep model inputs (8 representative days x 24 hours) from
the hourly timeseries + decision_variables_short.csv.

Reads:
    Temporal_Data/decision_variables_short.csv          (8 selected days + weights)
    Temporal_Data/Time_Series/timeseries_2022_A.csv     (DE)
    Temporal_Data/Time_Series/timeseries_2022_B.csv     (BE)
    Temporal_Data/Time_Series/timeseries_2022_C.csv     (NL)

Writes (to cross_border-CM-analysis/Input_192/):
    load.csv          192 rows x [A;B;C]   in MW
    wind_onshore.csv  192 rows x [A;B;C]   capacity factor 0..1
    pv.csv            192 rows x [A;B;C]   capacity factor 0..1
    weights.csv       192 rows x [A;B;C]   per-hour weight in hours-of-year
    period_map.csv    192 rows x [Timestep, Day, DayOfYear, HourOfDay, Weight_days]

Run:
    python build_inputs.py

Once you've reviewed the outputs, copy/replace the four CSVs into
cross_border-CM-analysis/Input/ and bump config.yaml: nTimesteps -> 192, nReprDays -> 8.
"""
from __future__ import annotations

from pathlib import Path
import pandas as pd

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

DECISION_FILE = HERE / "decision_variables_short.csv"
TS_DIR = HERE / "Time_Series"
OUT_DIR = ROOT / "cross_border-CM-analysis" / "Input_192"

ZONES = ["A", "B", "C"]            # A=DE, B=BE, C=NL
COUNTRY_LABEL = {"A": "DE", "B": "BE", "C": "NL"}

YEAR = 2022
HOURS_PER_DAY = 24


def load_decision_variables() -> pd.DataFrame:
    df = pd.read_csv(DECISION_FILE)
    df = df[df["selected_periods"]].reset_index(drop=True)
    df.index.name = "Day"  # rep day index 0..7
    print(f"Loaded {len(df)} representative days, weights sum = {df['weights'].sum():.2f}")
    return df  # columns: periods, weights, selected_periods


def load_zone_timeseries(zone: str) -> pd.DataFrame:
    f = TS_DIR / f"timeseries_{YEAR}_{zone}.csv"
    df = pd.read_csv(f)
    if len(df) != 8760:
        raise ValueError(f"{f} expected 8760 rows, got {len(df)}")
    return df


def slice_rep_days(zone_df: pd.DataFrame, periods: list[int], col: str) -> list[float]:
    """For each rep-day d (1-indexed day-of-year), return its 24 hourly values."""
    out: list[float] = []
    for d in periods:
        start = (d - 1) * HOURS_PER_DAY
        end = start + HOURS_PER_DAY
        out.extend(zone_df[col].iloc[start:end].tolist())
    return out


def make_timestamps(periods: list[int]) -> list[str]:
    """Honest ISO-ish timestamps tagged with the actual day-of-year of each rep day."""
    stamps = []
    for d in periods:
        # Convert day-of-year d to a 2022 calendar date.
        date = pd.Timestamp(f"{YEAR}-01-01") + pd.Timedelta(days=d - 1)
        for h in range(HOURS_PER_DAY):
            stamps.append(f"{date.strftime('%d-%m-%Y')} {h:02d}:00")
    return stamps


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    dec = load_decision_variables()
    periods = dec["periods"].astype(int).tolist()      # [32, 116, 138, ...]
    weights_per_day = dec["weights"].tolist()          # [43.53, 46.40, ...]

    zone_dfs = {z: load_zone_timeseries(z) for z in ZONES}

    timestamps = make_timestamps(periods)              # length 192

    # ----- LOAD -----
    load_df = pd.DataFrame({"": timestamps})
    for z in ZONES:
        load_df[z] = slice_rep_days(zone_dfs[z], periods, "LOAD")
    load_df.to_csv(OUT_DIR / "load.csv", sep=";", index=False)

    # ----- WIND ONSHORE -----
    wind_df = pd.DataFrame({"": timestamps})
    for z in ZONES:
        wind_df[z] = slice_rep_days(zone_dfs[z], periods, "WIND_ONSHORE")
    wind_df.to_csv(OUT_DIR / "wind_onshore.csv", sep=";", index=False)

    # ----- PV -----
    pv_df = pd.DataFrame({"": timestamps})
    for z in ZONES:
        pv_df[z] = slice_rep_days(zone_dfs[z], periods, "SOLAR")
    pv_df.to_csv(OUT_DIR / "pv.csv", sep=";", index=False)

    # ----- WEIGHTS -----
    # Each hour gets the weight (in hours-of-year) of the rep day it belongs to.
    # day_weight is in *days*; multiply by 1 (per-hour share = per-day share)
    # because 24 hours of rep-day stand for 24 * day_weight hours of year, so
    # each rep-hour represents day_weight hours of year.
    per_hour_weights = []
    for w in weights_per_day:
        per_hour_weights.extend([w] * HOURS_PER_DAY)
    weights_df = pd.DataFrame({z: per_hour_weights for z in ZONES})
    weights_df.to_csv(OUT_DIR / "weights.csv", sep=";", index=False)
    total_hours = sum(per_hour_weights)
    print(f"Weights sum to {total_hours:.2f} hours (target 8760).")

    # ----- PERIOD MAP (sidecar for traceability + the 'Day' column you asked for) -----
    rows = []
    for day_idx, (d, w) in enumerate(zip(periods, weights_per_day), start=1):
        for h in range(HOURS_PER_DAY):
            rows.append({
                "Timestep": (day_idx - 1) * HOURS_PER_DAY + h + 1,  # 1..192
                "Day": day_idx,                                      # 1..8
                "DayOfYear": d,                                      # 32, 116, ...
                "HourOfDay": h,                                      # 0..23
                "Weight_days": w,
            })
    pd.DataFrame(rows).to_csv(OUT_DIR / "period_map.csv", index=False)

    print(f"\nWrote 5 files to {OUT_DIR}")
    print("Next steps:")
    print(f"  1. Diff against {ROOT / 'cross_border-CM-analysis' / 'Input'}")
    print("  2. Copy load.csv, wind_onshore.csv, pv.csv, weights.csv into Input/")
    print("  3. Edit Input/config.yaml: nTimesteps -> 192, nReprDays -> 8")


if __name__ == "__main__":
    main()

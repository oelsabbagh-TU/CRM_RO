"""Extract national timeseries for LTTRS from ENTSO-E.

Usage:
	python extract_data.py            # default: BE
	python extract_data.py DE         # Germany     -> Zone A  (DE_LU bidding zone)
	python extract_data.py BE         # Belgium     -> Zone B
	python extract_data.py NL         # Netherlands -> Zone C

Output files:
	Input_stochastic/timeseries/timeseries_<year>_<ZONE>.csv for years 2017-2022.

Columns (matching existing LTTRS structure):
	times, LOAD, WIND_ONSHORE, WIND_OFFSHORE, SOLAR, DA_PRICES, LOAD_H2, ELASTICITY_EL
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
import time

import pandas as pd
import requests
from entsoe import EntsoePandasClient  # type: ignore[attr-defined]

API_KEY = os.environ.get("ENTSOE_API_KEY")
if not API_KEY:
	raise SystemExit(
		"ENTSOE_API_KEY environment variable not set. "
		"Get a free token from https://transparency.entsoe.eu/ (My Account > Web API), "
		"then export ENTSOE_API_KEY=<your-token> before running this script."
	)
client = EntsoePandasClient(api_key=API_KEY)

# country -> (ENTSO-E code, zone letter, local timezone)
# Mapping matches cross_border-CM-analysis/Input/config.yaml: A=DE, B=BE, C=NL.
COUNTRY_MAP = {
	"DE": ("DE_LU", "A", "Europe/Berlin"),
	"BE": ("BE",    "B", "Europe/Brussels"),
	"NL": ("NL",    "C", "Europe/Amsterdam"),
}

_country_arg = sys.argv[1].upper() if len(sys.argv) > 1 else "BE"
if _country_arg not in COUNTRY_MAP:
	raise SystemExit(f"Unknown country '{_country_arg}'. Choose from {list(COUNTRY_MAP)}.")

COUNTRY_CODE, ZONE_LETTER, TZ_NAME = COUNTRY_MAP[_country_arg]
COUNTRY_LABEL = _country_arg
YEARS = [2022]

# ENTSO-E PSR type mappings.
PSR_SOLAR = "B16"
PSR_WIND_OFFSHORE = "B18"
PSR_WIND_ONSHORE = "B19"

# Lightweight pacing to reduce risk of ENTSO-E throttling.
REQUEST_SLEEP_SECONDS = 1.0


def _coerce_to_series(value: pd.Series | pd.DataFrame | None, preferred: str | None = None) -> pd.Series:
	if value is None:
		return pd.Series(dtype="float64")
	if isinstance(value, pd.Series):
		return value.sort_index()

	if value.empty:
		return pd.Series(dtype="float64")

	numeric_cols = value.select_dtypes(include=["number"]).columns.tolist()
	if not numeric_cols:
		return pd.Series(dtype="float64")

	if preferred:
		preferred_matches = [c for c in numeric_cols if preferred.lower() in str(c).lower()]
		if preferred_matches:
			return value[preferred_matches[0]].sort_index()

	return value[numeric_cols[0]].sort_index()


def _to_hourly(series: pd.Series, index_hourly: pd.DatetimeIndex) -> pd.Series:
	if series.empty:
		return pd.Series(index=index_hourly, dtype="float64")

	s = series.copy().astype("float64")
	if not isinstance(s.index, pd.DatetimeIndex):
		raise TypeError(f"Expected DatetimeIndex, got {type(s.index)}")
	if s.index.tz is None:
		s.index = s.index.tz_localize(TZ_NAME)
	else:
		s = s.tz_convert(TZ_NAME)

	s = s.sort_index().resample("h").mean()
	s = s.reindex(index_hourly)
	s = s.ffill().bfill()
	return s


def _year_index(year: int) -> pd.DatetimeIndex:
	start = pd.Timestamp(f"{year}-01-01 00:00:00", tz=TZ_NAME)
	end = pd.Timestamp(f"{year + 1}-01-01 00:00:00", tz=TZ_NAME)
	idx = pd.date_range(start=start, end=end, freq="h", inclusive="left")

	# LTTRS files are fixed at 365 days * 24 hours = 8760 rows, so leap day is removed.
	idx = idx[~((idx.month == 2) & (idx.day == 29))]
	return idx


def _latest_capacity(series_or_df: pd.Series | pd.DataFrame | None) -> float:
	s = _coerce_to_series(series_or_df)
	s = pd.to_numeric(s, errors="coerce").dropna()
	if s.empty:
		return 0.0
	return float(s.iloc[-1])


def _safe_cf(gen_mw: pd.Series, installed_mw: float) -> pd.Series:
	if installed_mw <= 0.0:
		return pd.Series(0.0, index=gen_mw.index, dtype="float64")
	cf = gen_mw / installed_mw
	return cf.clip(lower=0.0, upper=1.0)


def _capacity_or_peak(
	cap_raw: pd.Series | pd.DataFrame | None,
	gen_series: pd.Series,
	label: str = "",
) -> float:
	"""Return installed capacity; fall back to peak observed generation if unavailable."""
	cap = _latest_capacity(cap_raw)
	if cap > 0:
		return cap
	peak = float(gen_series.max()) if not gen_series.empty else 0.0
	if peak > 0:
		# Assume peak generation corresponds to CF=0.8, so installed = peak / 0.8
		capacity = peak / 0.8
		print(f"  Warning: installed capacity unavailable{' for ' + label if label else ''}; using peak/{0.8} = {capacity:.0f} MW as proxy")
		return capacity
	return 0.0


def _iso_with_millis_and_offset(index: pd.DatetimeIndex) -> pd.Series:
	# Convert to ISO string with millisecond precision and explicit UTC offset.
	# Pass index= so the resulting Series shares the same DatetimeIndex as all
	# other columns, preventing pandas from outer-joining on mismatched indices.
	return pd.Series(index.strftime("%Y-%m-%dT%H:%M:%S.%f%z"), index=index).str.replace(
		r"(\d{3})\d{3}([+-]\d{2})(\d{2})$", r"\1\2:\3", regex=True
	)


def _query_with_pause(query_fn, *args, max_retries: int = 5, **kwargs):
	"""Call query_fn with retry on transient HTTP errors (5xx) using exponential backoff."""
	delay = 5.0
	for attempt in range(max_retries):
		try:
			result = query_fn(*args, **kwargs)
			time.sleep(REQUEST_SLEEP_SECONDS)
			return result
		except requests.exceptions.HTTPError as exc:
			status = exc.response.status_code if exc.response is not None else None
			if status is not None and 500 <= status < 600 and attempt < max_retries - 1:
				print(f"  HTTP {status} on attempt {attempt + 1}/{max_retries}, retrying in {delay:.0f}s...")
				time.sleep(delay)
				delay *= 2
			else:
				raise


def build_year_dataframe(client: EntsoePandasClient, year: int) -> pd.DataFrame:
	start = pd.Timestamp(f"{year}-01-01 00:00:00", tz=TZ_NAME)
	end = pd.Timestamp(f"{year + 1}-01-01 00:00:00", tz=TZ_NAME)
	# Extend capacity lookback by 1 year: ENTSO-E annual entries are often timestamped
	# at the start of the previous year, so they would be missed by a query starting on
	# Jan 1 of the target year.
	cap_start = pd.Timestamp(f"{year - 1}-01-01 00:00:00", tz=TZ_NAME)
	hourly_idx = _year_index(year)

	load_raw = _query_with_pause(client.query_load, COUNTRY_CODE, start=start, end=end)
	price_raw = _query_with_pause(
		client.query_day_ahead_prices, COUNTRY_CODE, start=start, end=end
	)

	gen_onshore_raw = _query_with_pause(
		client.query_generation, COUNTRY_CODE, start=start, end=end, psr_type=PSR_WIND_ONSHORE
	)
	gen_offshore_raw = _query_with_pause(
		client.query_generation,
		COUNTRY_CODE,
		start=start,
		end=end,
		psr_type=PSR_WIND_OFFSHORE,
	)
	gen_solar_raw = _query_with_pause(
		client.query_generation, COUNTRY_CODE, start=start, end=end, psr_type=PSR_SOLAR
	)

	cap_onshore_raw = _query_with_pause(
		client.query_installed_generation_capacity,
		COUNTRY_CODE,
		start=cap_start,
		end=end,
		psr_type=PSR_WIND_ONSHORE,
	)
	cap_offshore_raw = _query_with_pause(
		client.query_installed_generation_capacity,
		COUNTRY_CODE,
		start=cap_start,
		end=end,
		psr_type=PSR_WIND_OFFSHORE,
	)
	cap_solar_raw = _query_with_pause(
		client.query_installed_generation_capacity,
		COUNTRY_CODE,
		start=cap_start,
		end=end,
		psr_type=PSR_SOLAR,
	)

	load = _to_hourly(_coerce_to_series(load_raw, preferred="actual"), hourly_idx)
	prices = _to_hourly(_coerce_to_series(price_raw), hourly_idx)

	gen_onshore = _to_hourly(_coerce_to_series(gen_onshore_raw, preferred="actual"), hourly_idx)
	gen_offshore = _to_hourly(_coerce_to_series(gen_offshore_raw, preferred="actual"), hourly_idx)
	gen_solar = _to_hourly(_coerce_to_series(gen_solar_raw, preferred="actual"), hourly_idx)

	cap_onshore = _capacity_or_peak(cap_onshore_raw, gen_onshore, "Wind Onshore")
	cap_offshore = _capacity_or_peak(cap_offshore_raw, gen_offshore, "Wind Offshore")
	cap_solar = _capacity_or_peak(cap_solar_raw, gen_solar, "Solar")

	df = pd.DataFrame(
		{
			"times": _iso_with_millis_and_offset(hourly_idx),
			"LOAD": load.round(0).astype("int64"),
			"WIND_ONSHORE": _safe_cf(gen_onshore, cap_onshore),
			"WIND_OFFSHORE": _safe_cf(gen_offshore, cap_offshore),
			"SOLAR": _safe_cf(gen_solar, cap_solar),
			"DA_PRICES": prices,
			"LOAD_H2": 0,
			"ELASTICITY_EL": 0,
		}
	)

	if len(df) != 8760:
		raise ValueError(f"Expected 8760 rows for {year}, got {len(df)}")

	return df


def main() -> None:
	out_dir = Path(__file__).resolve().parent / "Time_Series"
	out_dir.mkdir(parents=True, exist_ok=True)

	for year in YEARS:
		print(f"Processing {COUNTRY_LABEL} (Zone {ZONE_LETTER}) for year {year}...")
		year_df = build_year_dataframe(client, year)

		out_file = out_dir / f"timeseries_{year}_{ZONE_LETTER}.csv"
		year_df.to_csv(out_file, index=False)
		print(f"Wrote {out_file} ({len(year_df)} rows)")


if __name__ == "__main__":
	main()

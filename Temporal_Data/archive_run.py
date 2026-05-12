"""Archive the latest MAIN.jl run into analysis_data/<design>/ so the RO
settlement script can pick it up.

Reads:
    cross_border-CM-analysis/Input/config.yaml      (to read the active "coupling")
    cross_border-CM-analysis/Results/Scenario_1_EOM_Zone_<Z>_ref.csv  (MCP outcome)
    cross_border-CM-analysis/Results/Planner/planner_zone_<Z>.csv    (planner ref)

Writes:
    cross_border-CM-analysis/analysis_data/<subdir>/mcp_zone_<Z>_<tag>.csv
    cross_border-CM-analysis/analysis_data/<subdir>/planner_zone_<Z>_<tag>.csv

Usage:
    python archive_run.py                       # auto-detect from config.yaml
    python archive_run.py FBMC                  # force a specific design tag
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
MODEL = HERE.parent / "cross_border-CM-analysis"

# config.coupling -> (analysis_data subdir, filename tag)
DESIGN_MAP = {
	"FB":       ("explicit_FBMC", "FBMC"),
	"ATC":      ("explicit_NTC",  "NTC"),
	"noCBP":    ("NoCBP",         "NoCBP"),
	"implicit": ("implicit",      "implicit"),
}

ZONES = ["A", "B", "C"]


def detect_design() -> tuple[str, str]:
	"""Return (subdir, tag) based on Input/config.yaml's coupling value."""
	cfg = yaml.safe_load((MODEL / "Input" / "config.yaml").read_text())
	coupling = cfg["Network"]["coupling"]
	if coupling not in DESIGN_MAP:
		raise SystemExit(f"coupling = '{coupling}' is not in {list(DESIGN_MAP)}")
	return DESIGN_MAP[coupling]


def main() -> None:
	if len(sys.argv) > 1:
		tag = sys.argv[1]
		# reverse-lookup subdir
		match = next(((sd, t) for sd, t in DESIGN_MAP.values() if t == tag), None)
		if match is None:
			raise SystemExit(f"tag '{tag}' not in {[t for _, t in DESIGN_MAP.values()]}")
		subdir, tag = match
	else:
		subdir, tag = detect_design()

	target = MODEL / "analysis_data" / subdir
	target.mkdir(parents=True, exist_ok=True)
	src_results = MODEL / "Results"

	moved = 0
	for z in ZONES:
		mcp_src     = src_results / f"Scenario_1_EOM_Zone_{z}_ref.csv"
		mcp_dst     = target / f"mcp_zone_{z}_{tag}.csv"
		planner_src = src_results / "Planner" / f"planner_zone_{z}.csv"
		planner_dst = target / f"planner_zone_{z}_{tag}.csv"

		for src, dst in [(mcp_src, mcp_dst), (planner_src, planner_dst)]:
			if not src.exists():
				print(f"  skip (missing): {src}")
				continue
			shutil.copy2(src, dst)
			print(f"  {src.name}  ->  {dst.relative_to(MODEL)}")
			moved += 1

	print(f"\nArchived {moved} files to {target.relative_to(MODEL)} (tag={tag}).")


if __name__ == "__main__":
	main()

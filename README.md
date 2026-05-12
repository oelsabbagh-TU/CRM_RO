# Cross-Border Reliability Options under Coupled Capacity Remuneration Mechanisms

This repository contains the model and analysis code for Osama Elsabbagh's MSc thesis at TU Delft on reliability-option (RO) settlement under coupled capacity remuneration mechanisms (CRMs).

## Relationship to Kamal Adekola's work

This codebase **extends** Kamal Adekola's three-zone capacity-market model, which is the upstream base for everything in `cross_border-CM-analysis/`.

- **Original repo:** https://github.com/kamaladekola/cross_border-CM
- **Original paper:** "Coupling Europe's Capacity Markets" (Adekola, 2026)

Kamal's model provides the ADMM-coordinated EOM + CM clearing across three zones (DE, BE, NL) under different cross-border coupling regimes (FB, ATC, NoCBP, implicit). This repository adds:

1. **Reliability-option settlement layer** (`cross_border-CM-analysis/RO_Settlement/`) — Julia post-processing that takes Kamal's per-zone EOM/CM outputs and computes hedge requirements (H), RO repayments (Π^RO), hedge shortfalls (Δ), CCRS allocations, and Ω-sufficiency tests for each cross-border RO contract. Implements the three-category settlement framework (Cat 1 / Cat 2 / Cat 3) from Chapter 2 of the thesis.

2. **Two-zone analytical companion** (`cross_border-CM-2zone/`) — A simplified two-zone variant of the same model, used in Chapter 3 to isolate the settlement mechanics from network/loop-flow effects.

3. **Temporal upgrade** (`Temporal_Data/`) — Scripts to (a) extract national timeseries from ENTSO-E, (b) build 192-timestep model inputs (8 representative days × 24 hours) from a Poncelet-style rep-day selection, (c) archive `MAIN.jl` runs into `analysis_data/<design>/` so the RO settlement can read them. Upgrades the original 24-timestep horizon to a full-year-equivalent representation while keeping the optimization tractable.

4. **Brownfield calibration** — Existing thermal fleet capacities (Baseload, MidMerit, Peak) are pinned to today's BE/DE/NL portfolios via the `C:` field per zone in `config.yaml`, replacing the greenfield optimization with a brownfield equilibrium that reflects the status-quo fleet rather than freely chosen capacity.

## Standard workflow

1. Edit `cross_border-CM-analysis/Input/config.yaml` — set `coupling:` to `"FB"`, `"ATC"`, `"noCBP"`, or `"implicit"`.
2. Run `julia MAIN.jl` from `cross_border-CM-analysis/`.
3. Run `python Temporal_Data/archive_run.py` to copy `Results/` into `analysis_data/<design>/` with the correct filename tag.
4. Repeat 1–3 for each design you need.
5. Run `julia RO_Settlement/RO_settlement.jl <K>` to compute settlements at strike price K (€/MWh).

## Dependencies

- **Julia** ≥ 1.9 with `JuMP`, `Gurobi`, `CSV`, `DataFrames`, `YAML`
- **Python** ≥ 3.10 with `pandas`, `requests`, `entsoe-py`, `pyyaml`
- **Gurobi** license

## License & attribution

This repository is an academic extension of Kamal Adekola's work. Please cite the original paper for the base model and the corresponding MSc thesis for the RO-settlement extension.

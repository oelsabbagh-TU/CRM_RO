# Two-zone A/B workspace

This folder is the self-contained reduced version of the cross-border capacity-market model.

## What is here
- `MAIN.jl`: two-zone equilibrium run for zones A and B only
- `RO_Settlement/RO_settlement_2zone.jl`: two-zone RO settlement and congestion-rent recovery check
- `RO_Settlement/CM_analysis.ipynb`: A/B capacity-market summary and figures
- `RO_Settlement/RO_analysis.ipynb`: A/B RO settlement summary and figures
- `Results/`: two-zone equilibrium outputs used by the notebooks
- `RO_Settlement/Results/`: two-zone RO outputs and generated figures

## Conventions
- zone C is excluded from the analysis notebooks
- the settlement extension uses the term **congestion-rent recovery** rather than FTR
- all plots and CSV outputs stay inside this workspace

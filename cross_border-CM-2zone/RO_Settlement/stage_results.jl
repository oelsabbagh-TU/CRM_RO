using CSV, DataFrames, YAML

# ─────────────────────────────────────────────────────────────────────────────
# stage_results.jl  —  runs after MAIN.jl to stage outputs for the settlement
#
# Kamal's MAIN.jl writes:
#   Results/Scenario_<N>_EOM_Zone_<Z>_<tag>.csv
#
# The settlement script expects:
#   analysis_data/<design_folder>/mcp_zone_<Z>_<design>.csv
#
# This script reads config.yaml to detect the coupling type, then copies
# the latest Results/ files into the right analysis_data location.
#
# Usage (from the RO_Settlement folder):
#   julia stage_results.jl              # scenario 1, tag "ref"
#   julia stage_results.jl 1 ref        # explicit scenario and tag
# ─────────────────────────────────────────────────────────────────────────────

const SCRIPT_DIR = @__DIR__
const MODEL_DIR  = abspath(joinpath(SCRIPT_DIR, ".."))
const ZONES      = ["A", "B"]

const SCEN_NUM = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1
const SENS_TAG = length(ARGS) >= 2 ? ARGS[2]             : "ref"

# coupling value in config.yaml → (design label, folder name)
const COUPLING_MAP = Dict(
    "FB"       => ("FBMC",     "explicit_FBMC"),
    "ATC"      => ("NTC",      "explicit_NTC"),
    "noCBP"    => ("NoCBP",    "NoCBP"),
    "implicit" => ("implicit", "implicit"),
    "pricecap" => ("pricecap", "pricecap"),
    "none"     => ("eom",      "eom"),
)

function main()
    cfg      = YAML.load_file(joinpath(MODEL_DIR, "Input", "config.yaml"))
    coupling = cfg["Network"]["coupling"]

    haskey(COUPLING_MAP, coupling) ||
        error("Unknown coupling type '$coupling' — add it to COUPLING_MAP in stage_results.jl")

    design_label, design_folder = COUPLING_MAP[coupling]
    dest_dir = joinpath(MODEL_DIR, "analysis_data", design_folder)
    mkpath(dest_dir)

    println("Staging results  |  coupling=$(coupling)  →  design=$(design_label)")

    for z in ZONES
        src  = joinpath(MODEL_DIR, "Results",
                        "Scenario_$(SCEN_NUM)_EOM_Zone_$(z)_$(SENS_TAG).csv")
        dest = joinpath(dest_dir, "mcp_zone_$(z)_$(design_label).csv")
        isfile(src) || error("Source file not found: $src\nRun MAIN.jl first.")
        cp(src, dest; force=true)
        println("  $src  →  $dest")
    end

    println("\nDone — run RO_settlement_2zone.jl next.")
end

main()

using CSV
using DataFrames
using Statistics
using Printf
using YAML

# ─────────────────────────────────────────────────────────────────────────────
# Reliability-Options settlement analysis — 3-zone variant
#
# Layout: cross_border-CM-analysis/RO_Settlement/RO_settlement.jl
# Reads:  cross_border-CM-analysis/analysis_data/<design>/mcp_zone_X_<design>.csv
#         cross_border-CM-analysis/Input/{config.yaml, lines.csv, ptdf.csv,
#                                     weights.csv}
# Writes: cross_border-CM-analysis/RO_Settlement/Results/
#
# What this script computes (per Chapter 3 of the thesis):
#
#   * Hedge requirement       H_z,t      = max(λ^e_z,t − K, 0) · q       (eq 3.4)
#   * RO repayment            Π^RO_i,t   = max(λ^e_z,t − K, 0) · y^cm    (eq 3.2)
#   * Hedge shortfall         Δ_AB,t     = H_A,t − Π^RO_B,t              (eq 3.7)
#   * FTR-like allocation     CR^alloc_AB,t = (λ_A,t − λ_B,t) · q_AB     (eq 3.11)
#   * FTR-like sufficiency    Ω_AB         = Σ_t W_t · (CR^alloc − Δ)    (eq 3.13)
#   * System CR_total          Σ_l (λ^+_l − λ^-_l) · f_l (realised flows)
#
# In the 3-zone meshed topology, the line flow vector f_{ℓ,t} is reconstructed
# from the zonal net positions (NetworkManager column of each zone's CSV) and
# the zonal PTDF matrix:  f_{ℓ,t} = −Σ_z PTDF_{ℓ,z} · g_{z,t}.  System-wide
# CR_total is then compared against the sum of obligation-level FTR-like
# allocations to test revenue adequacy.
# ─────────────────────────────────────────────────────────────────────────────
const SCRIPT_DIR = @__DIR__
const MODEL_DIR  = abspath(joinpath(SCRIPT_DIR, ".."))
const STRIKE_K   = isempty(ARGS) ? 500.0 : parse(Float64, ARGS[1])
const SRC        = "mcp"
const OUTPUT_DIR = joinpath(SCRIPT_DIR, "Results")
const ZONES      = ["A", "B", "C"]
const DESIGNS    = ["eom", "NoCBP", "implicit", "pricecap", "FBMC", "NTC"]

# ─────────────────────────────────────────────────────────────────────────────
# Data loading
# ─────────────────────────────────────────────────────────────────────────────
function load_weights()::Vector{Float64}
    path = joinpath(MODEL_DIR, "Input", "weights.csv")
    df   = CSV.read(path, DataFrame; delim=";")
    return Float64.(df[!, Symbol(first(names(df)))])
end

function load_lines()::DataFrame
    return CSV.read(joinpath(MODEL_DIR, "Input", "lines.csv"),
                    DataFrame; delim=";")
end

function load_zonal_ptdf()::DataFrame
    return CSV.read(joinpath(MODEL_DIR, "Input", "ptdf.csv"),
                    DataFrame; delim=";")
end

function load_zone_map()::Dict{String,String}
    cfg  = YAML.load_file(joinpath(MODEL_DIR, "Input", "config.yaml"))
    zmap = Dict{String,String}()
    for (z, nodes) in cfg["Network"]["ZoneMap"]
        for n in nodes
            zmap[String(n)] = String(z)
        end
    end
    return zmap
end

function design_folder(design::AbstractString)::String
    design == "FBMC" && return "explicit_FBMC"
    design == "NTC"  && return "explicit_NTC"
    return design
end

function load_zone_data(design, zone)
    path = joinpath(MODEL_DIR, "analysis_data", design_folder(design),
                    "$(SRC)_zone_$(zone)_$(design).csv")
    isfile(path) || error("Missing file: $path")
    return CSV.read(path, DataFrame; delim=";")
end

function load_cb_capacity(design, zone)::Float64
    df = load_zone_data(design, zone)
    for col in (:CapacityManager, :TotalCapOffer)
        col in propertynames(df) && return abs(Float64(df[1, col]))
    end
    return 0.0
end

function net_position_annual(design, zone)::Float64
    df = load_zone_data(design, zone)
    for col in (:CapacityManager, :TotalCapOffer)
        col in propertynames(df) && return Float64(df[1, col])
    end
    return 0.0
end

is_net_exporter(design, zone) = net_position_annual(design, zone) < -1e-6
is_net_importer(design, zone) = net_position_annual(design, zone) >  1e-6

# ─────────────────────────────────────────────────────────────────────────────
# Per-design network-flow reconstruction
#
# The realised line flow vector is recovered from the zonal net positions
# (NetworkManager column of each zone's analysis CSV) and the zonal PTDF
# matrix:  f_{ℓ,t} = −Σ_z PTDF_{ℓ,z} · g_{z,t}, where g_{z,t} is import-positive.
# ─────────────────────────────────────────────────────────────────────────────
function reconstruct_line_flows(design, zones, lines, ptdf)
    nT = nrow(load_zone_data(design, first(zones)))
    nL = nrow(lines)
    f  = zeros(nT, nL)

    # zonal net positions g[t,z]
    g = zeros(nT, length(zones))
    for (jz, z) in enumerate(zones)
        df = load_zone_data(design, z)
        :NetworkManager in propertynames(df) ||
            error("Zone $z CSV missing NetworkManager column.")
        g[:, jz] = Float64.(df.NetworkManager)
    end

    # f[t,l] = −Σ_z PTDF[l,z] · g[t,z]
    for jl in 1:nL, jt in 1:nT
        f[jt, jl] = -sum(Float64(ptdf[jl, Symbol(zones[jz])]) * g[jt, jz]
                          for jz in 1:length(zones))
    end
    return f, g
end

# ─────────────────────────────────────────────────────────────────────────────
# Category classification (Chapter 2 / Table 2.1)
# ─────────────────────────────────────────────────────────────────────────────
function classify(p_imp::Float64, p_exp::Float64, k::Float64)::Tuple{Int,String}
    a = p_imp > k
    b = p_exp > k
    a &&  b && return (2, "Cat 2 — Scarcity in both zones")
    a && !b && return (1, "Cat 1 — Scarcity in importing zone only")
   !a &&  b && return (3, "Cat 3 — Scarcity in exporting zone only")
    return (0, "No scarcity")
end

shortfall_type(d::Float64) = d > 1e-6 ? "Under-compensated" :
                              d < -1e-6 ? "Over-compensated" : "Perfectly hedged"
omega_type(o::Float64)     = o > 1e-6 ? "Surplus rent (CR^alloc > Δ)" :
                              o < -1e-6 ? "Deficit (CR^alloc < Δ)"     :
                                           "Exactly funded"

# ─────────────────────────────────────────────────────────────────────────────
# Per-timestep settlement events for a single (design, exporter, importer)
# obligation, with the FTR-like allocation CR^alloc_AB,t = (λ_A − λ_B) · q.
# ─────────────────────────────────────────────────────────────────────────────
function build_events(design, exporter, importer, k, weights)
    exp_df = load_zone_data(design, exporter)
    imp_df = load_zone_data(design, importer)
    q      = load_cb_capacity(design, exporter)

    n    = min(nrow(exp_df), nrow(imp_df), length(weights))
    rows = NamedTuple[]

    for i in 1:n
        p_exp = Float64(exp_df.EOM_price[i])
        p_imp = Float64(imp_df.EOM_price[i])
        w     = Float64(weights[i])
        ts    = Int(exp_df.Timestep[i])

        cat, cat_label = classify(p_imp, p_exp, k)

        H_A   = q * max(p_imp - k, 0.0)
        Pi_RO = q * max(p_exp - k, 0.0)
        delta = H_A - Pi_RO
        cr_alloc = (p_imp - p_exp) * q
        omega    = cr_alloc - delta

        # Keep only timesteps where at least one zone is in scarcity (Cat 1/2/3).
        if cat == 0
            continue
        end

        # Shortfall hedging: when Δ > 0, does CR^alloc cover it?
        shortfall_exists    = delta > 1e-6
        shortfall_hedged    = shortfall_exists && (cr_alloc >= delta - 1e-6)
        covered_EUR         = shortfall_exists ? min(cr_alloc, delta) : 0.0
        uncovered_EUR       = shortfall_exists ? max(delta - cr_alloc, 0.0) : 0.0
        coverage_ratio_ts   = shortfall_exists ? clamp(cr_alloc / delta, 0.0, 1.0) : NaN

        push!(rows, (
            Design                          = design,
            Contract                        = "$(exporter)→$(importer)",
            Exporter                        = exporter,
            Importer                        = importer,
            Timestep                        = ts,
            Weight_h                        = w,
            Strike_K_EUR_per_MWh            = k,
            Capacity_MW                     = q,
            P_Exporter_EUR_per_MWh          = p_exp,
            P_Importer_EUR_per_MWh          = p_imp,
            Category                        = cat,
            Category_Label                  = cat_label,
            HedgeRequirement_EUR_per_h      = H_A,
            RO_Repayment_EUR_per_h          = Pi_RO,
            HedgeShortfall_EUR_per_h        = delta,
            ShortfallType                   = shortfall_type(delta),
            CR_Alloc_EUR_per_h              = cr_alloc,
            FTRlike_Omega_EUR_per_h         = omega,
            OmegaType                       = omega_type(omega),
            Shortfall_Exists                = shortfall_exists,
            Shortfall_Hedged                = shortfall_hedged,
            Shortfall_Covered_EUR_per_h     = covered_EUR,
            Shortfall_Uncovered_EUR_per_h   = uncovered_EUR,
            Shortfall_Coverage_Ratio        = coverage_ratio_ts,
            Weighted_Delta_EUR              = delta    * w,
            Weighted_CR_Alloc_EUR           = cr_alloc * w,
            Weighted_Omega_EUR              = omega    * w,
            Weighted_Covered_EUR            = covered_EUR   * w,
            Weighted_Uncovered_EUR          = uncovered_EUR * w,
        ))
    end

    isempty(rows) && return DataFrame()
    return DataFrame(rows)
end

# ─────────────────────────────────────────────────────────────────────────────
# Contract-level annual summary
# ─────────────────────────────────────────────────────────────────────────────
function build_summary(events::DataFrame)::DataFrame
    rows = NamedTuple[]
    for grp in groupby(events, [:Design, :Contract, :Exporter, :Importer])
        d   = first(grp.Design)
        con = first(grp.Contract)
        exp = first(grp.Exporter)
        imp = first(grp.Importer)
        q   = first(grp.Capacity_MW)
        k   = first(grp.Strike_K_EUR_per_MWh)

        scarcity = grp[grp.Category .> 0, :]
        c1 = grp[grp.Category .== 1, :]
        c2 = grp[grp.Category .== 2, :]
        c3 = grp[grp.Category .== 3, :]

        ann_H        = sum(grp.HedgeRequirement_EUR_per_h .* grp.Weight_h) / 1e6
        ann_PiRO     = sum(grp.RO_Repayment_EUR_per_h     .* grp.Weight_h) / 1e6
        ann_delta    = sum(grp.Weighted_Delta_EUR)                          / 1e6
        ann_cr_alloc = sum(grp.Weighted_CR_Alloc_EUR)                       / 1e6
        ann_omega    = sum(grp.Weighted_Omega_EUR)                          / 1e6

        coverage = abs(ann_delta) > 1e-9 ? ann_cr_alloc / ann_delta : NaN

        # Shortfall hedging statistics (timestep-level)
        sf_rows   = grp[grp.Shortfall_Exists, :]
        sf_h_tot  = nrow(sf_rows) > 0 ? sum(sf_rows.Weight_h)                        : 0.0
        sf_h_hed  = nrow(sf_rows) > 0 ? sum(sf_rows.Weight_h[sf_rows.Shortfall_Hedged]) : 0.0
        sf_h_frac = sf_h_tot > 1e-9   ? sf_h_hed / sf_h_tot                          : NaN
        ann_covered   = sum(grp.Weighted_Covered_EUR)   / 1e6
        ann_uncovered = sum(grp.Weighted_Uncovered_EUR) / 1e6
        ann_sf_total  = ann_covered + ann_uncovered
        eur_coverage  = ann_sf_total > 1e-9 ? ann_covered / ann_sf_total             : NaN

        push!(rows, (
            Design                          = d,
            Contract                        = con,
            Exporter                        = exp,
            Importer                        = imp,
            Capacity_MW                     = q,
            Strike_K_EUR_per_MWh            = k,
            Cat1_Hours_Weighted             = nrow(c1) > 0 ? sum(c1.Weight_h) : 0.0,
            Cat2_Hours_Weighted             = nrow(c2) > 0 ? sum(c2.Weight_h) : 0.0,
            Cat3_Hours_Weighted             = nrow(c3) > 0 ? sum(c3.Weight_h) : 0.0,
            Total_Scarcity_Hours_Weighted   = nrow(scarcity) > 0 ? sum(scarcity.Weight_h) : 0.0,
            Total_RentFlow_Hours_Weighted   = sum(grp.Weight_h),
            Annual_HedgeRequirement_MEUR    = ann_H,
            Annual_RO_Repayment_MEUR        = ann_PiRO,
            Annual_HedgeShortfall_MEUR      = ann_delta,
            Annual_CR_Alloc_MEUR            = ann_cr_alloc,
            Annual_FTRlike_Omega_MEUR       = ann_omega,
            Coverage_Ratio_CRalloc_over_Δ   = coverage,
            Shortfall_Hours_Weighted        = sf_h_tot,
            Hedged_Shortfall_Hours_Weighted = sf_h_hed,
            Shortfall_Hour_Coverage_pct     = sf_h_frac * 100,
            Annual_Shortfall_Covered_MEUR   = ann_covered,
            Annual_Shortfall_Uncovered_MEUR = ann_uncovered,
            Annual_EUR_Coverage_Ratio       = eur_coverage,
            Settlement_Outcome = ann_delta >  1e-9 ? "Net under-compensation by RO alone" :
                                 ann_delta < -1e-9 ? "Net over-compensation by RO alone"  :
                                                     "RO net zero shortfall",
            FTRlike_Outcome    = ann_omega >  1e-9 ? "FTR-like surplus (rent > shortfall)" :
                                 ann_omega < -1e-9 ? "FTR-like deficit (rent < shortfall)" :
                                                     "FTR-like exactly funds shortfall",
            Hedge_Outcome      = isnan(eur_coverage)  ? "No shortfall" :
                                 eur_coverage >= 1.0 - 1e-6 ? "Fully hedged by FTR-like rent" :
                                 eur_coverage >= 0.5        ? "Partially hedged (>50%)"       :
                                                              "Largely unhedged (<50%)",
        ))
    end
    return DataFrame(rows)
end

# ─────────────────────────────────────────────────────────────────────────────
# Per-design system-level revenue adequacy
#
# Total realised congestion rent is computed line-by-line from reconstructed
# flows and the zonal price differences across each line's endpoints. The sum
# of obligation-level FTR-like allocations across all (exporter, importer)
# pairs in this design is then compared against that total to test
# revenue adequacy.
# ─────────────────────────────────────────────────────────────────────────────
function design_revenue_adequacy(design, weights, zones, lines, ptdf, zone_map)
    # Reconstruct line flows for the design
    f, _ = reconstruct_line_flows(design, zones, lines, ptdf)

    # Pull zonal prices for the design
    nT = size(f, 1)
    prices = zeros(nT, length(zones))
    for (jz, z) in enumerate(zones)
        prices[:, jz] = Float64.(load_zone_data(design, z).EOM_price)
    end
    zone_idx = Dict(z => jz for (jz, z) in enumerate(zones))

    # Per-line price difference (Δλ_l = λ_to_zone − λ_from_zone). Internal
    # lines (from_zone == to_zone) contribute zero.
    nL = nrow(lines)
    cr_total = zeros(nT)
    for jl in 1:nL
        from_node = String(lines.from[jl])
        to_node   = String(lines.to[jl])
        from_z    = zone_map[from_node]
        to_z      = zone_map[to_node]
        from_z == to_z && continue   # internal line, no price spread
        for jt in 1:nT
            dλ = prices[jt, zone_idx[to_z]] - prices[jt, zone_idx[from_z]]
            cr_total[jt] += dλ * f[jt, jl]
        end
    end

    # Annual total congestion rent on realised flows
    n = min(nT, length(weights))
    ann_cr_total = sum(weights[1:n] .* cr_total[1:n]) / 1e6

    return ann_cr_total, cr_total
end

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
function main()
    mkpath(OUTPUT_DIR)
    weights  = load_weights()
    lines    = load_lines()
    ptdf     = load_zonal_ptdf()
    zone_map = load_zone_map()
    tag      = "K$(Int(STRIKE_K))"

    println("\nRO Settlement Analysis (3-zone)  |  Strike K = $(STRIKE_K) EUR/MWh")
    println("="^72)
    println("Input data  : $MODEL_DIR")
    println("Output dir  : $OUTPUT_DIR")
    println()

    all_events  = DataFrame[]
    sys_summary = NamedTuple[]

    for design in DESIGNS
        # Skip designs that have no analysis data (e.g. eom doesn't run all designs)
        try
            load_zone_data(design, "A")
        catch
            continue
        end

        # Per-pair settlement events
        for exporter in ZONES, importer in ZONES
            exporter == importer && continue
            is_net_exporter(design, exporter) || continue
            is_net_importer(design, importer) || continue
            q = load_cb_capacity(design, exporter)
            q < 1e-6 && continue
            df = build_events(design, exporter, importer, STRIKE_K, weights)
            isempty(df) || push!(all_events, df)
        end

        # System-level CR_total via line-flow reconstruction
        ann_cr_total, _ = design_revenue_adequacy(design, weights, ZONES, lines,
                                                  ptdf, zone_map)
        push!(sys_summary, (Design = design,
                            Annual_CR_Total_MEUR = ann_cr_total))
    end

    if isempty(all_events)
        println("No events found across designs.")
        return
    end

    events  = vcat(all_events...)
    sort!(events, [:Design, :Contract, :Timestep])
    summary = build_summary(events)
    sort!(summary, [:Design, :Contract])

    # Per-design aggregate Ω vs realised CR_total
    sys_summary_df = DataFrame(sys_summary)
    by_design = combine(groupby(summary, :Design),
        :Annual_HedgeShortfall_MEUR => sum  => :SumDelta_MEUR,
        :Annual_CR_Alloc_MEUR       => sum  => :SumCRAlloc_MEUR,
        :Annual_FTRlike_Omega_MEUR  => sum  => :SumOmega_MEUR)
    revenue_adequacy = leftjoin(by_design, sys_summary_df, on = :Design)
    revenue_adequacy.RevAdequacy_CRtotal_minus_CRalloc_MEUR =
        revenue_adequacy.Annual_CR_Total_MEUR .- revenue_adequacy.SumCRAlloc_MEUR

    # ── Write CSV outputs ────────────────────────────────────────────────────
    events_path  = joinpath(OUTPUT_DIR, "ro_settlement_events_$(tag).csv")
    summary_path = joinpath(OUTPUT_DIR, "ro_settlement_summary_$(tag).csv")
    revadq_path  = joinpath(OUTPUT_DIR, "ro_revenue_adequacy_$(tag).csv")
    CSV.write(events_path,  events;            delim=";")
    CSV.write(summary_path, summary;           delim=";")
    CSV.write(revadq_path,  revenue_adequacy;  delim=";")

    println("Output files written:")
    println("  $events_path")
    println("  $summary_path")
    println("  $revadq_path\n")

    # ── Summary ──────────────────────────────────────────────────────────────
    println("RO Settlement  |  K = $(STRIKE_K) €/MWh  |  scarcity events")
    println("─"^105)
    @printf("%-8s  %-8s  %9s  %9s  %9s  %8s  %10s  %8s  %-30s\n",
        "Design","Contract","H (M€)","Δ (M€)","Uncvd (M€)","Hed hrs%","EUR cov%","CR_total","Hedge outcome")
    println("─"^105)
    cr_map = Dict(r.Design => r.Annual_CR_Total_MEUR for r in eachrow(revenue_adequacy))
    for r in eachrow(summary)
        hed_pct = isnan(r.Shortfall_Hour_Coverage_pct) ? "    N/A" :
                  @sprintf("%7.1f%%", r.Shortfall_Hour_Coverage_pct)
        eur_pct = isnan(r.Annual_EUR_Coverage_Ratio)   ? "    N/A" :
                  @sprintf("%7.1f%%", r.Annual_EUR_Coverage_Ratio * 100)
        cr_tot  = get(cr_map, r.Design, NaN)
        @printf("%-8s  %-8s  %9.4f  %9.4f  %9.4f  %8s  %8s  %8.4f  %-30s\n",
            r.Design, r.Contract,
            r.Annual_HedgeRequirement_MEUR,
            r.Annual_HedgeShortfall_MEUR,
            r.Annual_Shortfall_Uncovered_MEUR,
            hed_pct, eur_pct, cr_tot,
            r.Hedge_Outcome)
    end
    println()
end

main()
